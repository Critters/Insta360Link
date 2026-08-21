#!/usr/bin/env python3
"""Insta360 Link PTZ and occupancy helper for the Omarchy plugin."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

DEVICE_CANDIDATES = (
    "/dev/v4l/by-id/usb-Insta360_Insta360_Link-video-index0",
    "/dev/video0",
)

IGNORE_COMMS = {
    "pipewire",
    "pipewire-pulse",
    "wireplumber",
    "quickshell",
    "v4l2-ctl",
    "xdg-desktop-portal",
    "xdg-desktop-por",  # comm is truncated to 15 chars
    "xdg-document-po",
}

CTRL_RE = re.compile(
    r"^\s*(pan_absolute|tilt_absolute|zoom_absolute)\s+\S+\s+\(int\)\s*:"
    r"\s*min=([-\d]+)\s+max=([-\d]+)\s+step=(\d+)"
    r".*\bvalue=([-\d]+)",
    re.M,
)

APP_LABELS = (
    ("zoom", "Zoom"),
    ("obs", "OBS"),
    ("discord", "Discord"),
    ("firefox", "Firefox"),
    ("chrome", "Chrome"),
    ("chromium", "Chromium"),
    ("google-chrome", "Chrome"),
    ("slack", "Slack"),
    ("chromium-browser", "Chromium"),
)


def die(message: str, code: int = 1) -> None:
    print(json.dumps({"error": message}), file=sys.stderr)
    sys.exit(code)


def run(cmd: list[str], timeout: float = 2.0) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=False, capture_output=True, text=True, timeout=timeout)


def find_device() -> str | None:
    for path in DEVICE_CANDIDATES:
        if not os.path.exists(path):
            continue
        try:
            proc = run(["v4l2-ctl", "-d", path, "--list-ctrls"], timeout=1.5)
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
        if proc.returncode == 0 and "pan_absolute" in proc.stdout:
            return path
    return None


def parse_ctrls(text: str) -> dict[str, dict[str, int]]:
    out: dict[str, dict[str, int]] = {}
    for match in CTRL_RE.finditer(text):
        name, min_s, max_s, step_s, value_s = match.groups()
        key = name.replace("_absolute", "")
        out[key] = {
            "min": int(min_s),
            "max": int(max_s),
            "step": int(step_s),
            "value": int(value_s),
        }
    return out


def read_ctrls(device: str) -> dict[str, dict[str, int]]:
    proc = run(["v4l2-ctl", "-d", device, "--list-ctrls"], timeout=1.5)
    if proc.returncode != 0:
        die(proc.stderr.strip() or "v4l2-ctl --list-ctrls failed")
    ctrls = parse_ctrls(proc.stdout)
    if "pan" not in ctrls or "tilt" not in ctrls or "zoom" not in ctrls:
        die("camera is missing pan/tilt/zoom controls")
    return ctrls


def snap(value: int, spec: dict[str, int]) -> int:
    lo, hi, step = spec["min"], spec["max"], spec["step"] or 1
    value = max(lo, min(hi, int(value)))
    return lo + round((value - lo) / step) * step


def pose_from_ctrls(ctrls: dict[str, dict[str, int]]) -> dict[str, int]:
    return {
        "pan": ctrls["pan"]["value"],
        "tilt": ctrls["tilt"]["value"],
        "zoom": ctrls["zoom"]["value"],
    }


def cmd_device() -> None:
    device = find_device()
    print(json.dumps({"device": device or ""}))


def cmd_get() -> None:
    device = find_device()
    if not device:
        print(json.dumps({"present": False}))
        return
    ctrls = read_ctrls(device)
    print(json.dumps({"present": True, "device": device, "pose": pose_from_ctrls(ctrls), "ranges": ctrls}))


def cmd_set(pan: int, tilt: int, zoom: int) -> None:
    device = find_device()
    if not device:
        die("camera not found")
    ctrls = read_ctrls(device)
    pan_v = snap(pan, ctrls["pan"])
    tilt_v = snap(tilt, ctrls["tilt"])
    zoom_v = snap(zoom, ctrls["zoom"])
    proc = run(
        [
            "v4l2-ctl",
            "-d",
            device,
            "--set-ctrl",
            f"pan_absolute={pan_v},tilt_absolute={tilt_v},zoom_absolute={zoom_v}",
        ],
        timeout=2.5,
    )
    if proc.returncode != 0:
        die(proc.stderr.strip() or "v4l2-ctl --set-ctrl failed")
    print(json.dumps({"present": True, "device": device, "pose": {"pan": pan_v, "tilt": tilt_v, "zoom": zoom_v}}))


def label_for(name: str) -> str:
    lowered = name.lower()
    for needle, label in APP_LABELS:
        if needle in lowered:
            return label
    return name


def comm_for(pid: str) -> str:
    try:
        with open(f"/proc/{pid}/comm", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def cmdline_for(pid: str) -> str:
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as fh:
            return fh.read().replace(b"\x00", b" ").decode("utf-8", "replace")
    except OSError:
        return ""


def is_self(pid: str) -> bool:
    cmd = cmdline_for(pid)
    return "ptz.py" in cmd


def is_ignored(pid: str) -> bool:
    if is_self(pid):
        return True
    name = comm_for(pid)
    if name in IGNORE_COMMS:
        return True
    if name.startswith("xdg-desktop-po"):
        return True
    return False


def v4l2_holders(device: str) -> list[str]:
    real = os.path.realpath(device)
    want = {device, real}
    holders: list[str] = []
    try:
        pids = os.listdir("/proc")
    except OSError:
        return holders
    for pid in pids:
        if not pid.isdigit() or is_ignored(pid):
            continue
        fd_dir = f"/proc/{pid}/fd"
        try:
            fds = os.listdir(fd_dir)
        except OSError:
            continue
        for fd in fds:
            try:
                target = os.readlink(f"{fd_dir}/{fd}")
            except OSError:
                continue
            if target in want:
                holders.append(label_for(comm_for(pid)))
                break
    return holders


def pipewire_video(device: str) -> dict[str, object]:
    try:
        proc = run(["pw-dump"], timeout=2.0)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return {"running": False, "app": ""}
    if proc.returncode != 0:
        return {"running": False, "app": ""}
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {"running": False, "app": ""}

    real = os.path.realpath(device)
    camera_id = None
    nodes: dict[int, dict] = {}
    for obj in data:
        if obj.get("type") != "PipeWire:Interface:Node":
            continue
        info = obj.get("info") or {}
        props = info.get("props") or {}
        oid = obj.get("id")
        if oid is None:
            continue
        nodes[int(oid)] = {"info": info, "props": props}
        media = str(props.get("media.class") or "")
        path = str(props.get("api.v4l2.path") or props.get("object.path") or "")
        desc = str(props.get("node.description") or props.get("node.nick") or "")
        if media != "Video/Source":
            continue
        if real in path or device in path or "Insta360" in desc:
            camera_id = int(oid)

    if camera_id is None:
        return {"running": False, "app": ""}

    cam = nodes[camera_id]
    running = str(cam["info"].get("state") or "") == "running"
    app = ""
    for obj in data:
        if obj.get("type") != "PipeWire:Interface:Link":
            continue
        info = obj.get("info") or {}
        out_id = info.get("output-node-id")
        in_id = info.get("input-node-id")
        other = None
        if out_id == camera_id:
            other = nodes.get(int(in_id)) if in_id is not None else None
        elif in_id == camera_id:
            other = nodes.get(int(out_id)) if out_id is not None else None
        if not other:
            continue
        props = other["props"]
        raw = str(props.get("application.name") or props.get("application.process.binary") or "")
        if raw:
            app = label_for(raw)
            running = True
            break
    return {"running": bool(running), "app": app}


def cmd_occupancy() -> None:
    device = find_device()
    if not device:
        print(json.dumps({"state": "missing", "via": "", "app": "", "device": ""}))
        return
    holders = v4l2_holders(device)
    pw = pipewire_video(device)
    if holders:
        print(json.dumps({"state": "live", "via": "v4l2", "app": holders[0], "device": device}))
        return
    if pw.get("running"):
        print(json.dumps({"state": "live", "via": "pw", "app": pw.get("app") or "", "device": device}))
        return
    print(json.dumps({"state": "idle", "via": "", "app": "", "device": device}))


def usage() -> None:
    print("usage: ptz.py device|get|set PAN TILT ZOOM|occupancy", file=sys.stderr)
    sys.exit(2)


def main(argv: list[str]) -> None:
    if len(argv) < 2:
        usage()
    cmd = argv[1]
    if cmd == "device":
        cmd_device()
    elif cmd == "get":
        cmd_get()
    elif cmd == "set":
        if len(argv) != 5:
            usage()
        cmd_set(int(argv[2]), int(argv[3]), int(argv[4]))
    elif cmd == "occupancy":
        cmd_occupancy()
    else:
        usage()


if __name__ == "__main__":
    main(sys.argv)
