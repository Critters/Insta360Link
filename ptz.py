#!/usr/bin/env python3
"""Insta360 Link PTZ and occupancy helper for the Omarchy plugin."""

from __future__ import annotations

import ctypes
import fcntl
import json
import os
import re
import struct
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
    "python3",
    "python",
    "xdg-desktop-portal",
    "xdg-desktop-por",  # comm is truncated to 15 chars
    "xdg-document-po",
}

V4L2_CID_PAN_ABSOLUTE = 0x009A0908
V4L2_CID_TILT_ABSOLUTE = 0x009A0909
V4L2_CID_ZOOM_ABSOLUTE = 0x009A090D

# _IOWR('V', 27/28, struct v4l2_control) with 8-byte payload
_VIDIOC_G_CTRL = 0xC008561B
_VIDIOC_S_CTRL = 0xC008561C

UVC_SET_CUR = 0x01
UVC_GET_LEN = 0x85
XU_UNIT = 9
XU_MODE = 2
XU_MODE_LEN = 52


class UvcXuQuery(ctypes.Structure):
    _fields_ = [
        ("unit", ctypes.c_uint8),
        ("selector", ctypes.c_uint8),
        ("query", ctypes.c_uint8),
        ("size", ctypes.c_uint16),
        ("data", ctypes.c_void_p),
    ]


def _ioc(direction: int, type_ch: str, nr: int, size: int) -> int:
    return (direction << 30) | (ord(type_ch) << 8) | nr | (size << 16)


UVCIOC_CTRL_QUERY = _ioc(3, "u", 0x21, ctypes.sizeof(UvcXuQuery))

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
        if os.path.exists(path):
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


def s_ctrl(fd: int, ctrl_id: int, value: int) -> None:
    packed = struct.pack("Ii", ctrl_id, int(value))
    fcntl.ioctl(fd, _VIDIOC_S_CTRL, packed)


def g_ctrl(fd: int, ctrl_id: int) -> int:
    buf = bytearray(struct.pack("Ii", ctrl_id, 0))
    fcntl.ioctl(fd, _VIDIOC_G_CTRL, buf)
    _cid, value = struct.unpack("Ii", bytes(buf))
    return value


class _ExtCtrl(ctypes.Structure):
    _pack_ = 1
    _layout_ = "ms"
    _fields_ = [
        ("id", ctypes.c_uint32),
        ("size", ctypes.c_uint32),
        ("reserved2", ctypes.c_uint32),
        ("value64", ctypes.c_int64),
    ]


class _ExtCtrls(ctypes.Structure):
    _fields_ = [
        ("which", ctypes.c_uint32),
        ("count", ctypes.c_uint32),
        ("error_idx", ctypes.c_uint32),
        ("request_fd", ctypes.c_int32),
        ("reserved", ctypes.c_uint32),
        ("controls", ctypes.POINTER(_ExtCtrl)),
    ]


_VIDIOC_S_EXT_CTRLS = _ioc(3, "V", 72, ctypes.sizeof(_ExtCtrls))

PAN_RANGE = {"min": -522000, "max": 522000, "step": 3600}
TILT_RANGE = {"min": -324000, "max": 360000, "step": 3600}
ZOOM_RANGE = {"min": 100, "max": 400, "step": 1}
FINE_STEP = {"pan": 3600, "tilt": 7200, "zoom": 7}
FAST_STEP = {"pan": 10800, "tilt": 18000, "zoom": 14}


def s_ext_pan_tilt(fd: int, pan: int, tilt: int) -> None:
    ctrls = (_ExtCtrl * 2)()
    ctrls[0].id = V4L2_CID_PAN_ABSOLUTE
    ctrls[0].value64 = int(pan)
    ctrls[1].id = V4L2_CID_TILT_ABSOLUTE
    ctrls[1].value64 = int(tilt)
    wrap = _ExtCtrls(0, 2, 0, -1, 0, ctypes.cast(ctrls, ctypes.POINTER(_ExtCtrl)))
    fcntl.ioctl(fd, _VIDIOC_S_EXT_CTRLS, wrap)


def xu_set(fd: int, selector: int, data: bytes) -> None:
    buf = (ctypes.c_uint8 * len(data)).from_buffer_copy(bytearray(data))
    query = UvcXuQuery(XU_UNIT, selector, UVC_SET_CUR, len(data), ctypes.addressof(buf))
    fcntl.ioctl(fd, UVCIOC_CTRL_QUERY, query)


def mode_off(fd: int) -> None:
    try:
        xu_set(fd, XU_MODE, bytes(XU_MODE_LEN))
    except OSError:
        pass


def open_device(path: str) -> int:
    return os.open(os.path.realpath(path), os.O_RDWR)


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


def cmd_set(pan: int, tilt: int, zoom: int, unlock: bool = False) -> None:
    device = find_device()
    if not device:
        die("camera not found")
    ctrls = read_ctrls(device)
    pan_v = snap(pan, ctrls["pan"])
    tilt_v = snap(tilt, ctrls["tilt"])
    zoom_v = snap(zoom, ctrls["zoom"])
    fd = open_device(device)
    try:
        if unlock:
            mode_off(fd)
        s_ext_pan_tilt(fd, pan_v, tilt_v)
        s_ctrl(fd, V4L2_CID_ZOOM_ABSOLUTE, zoom_v)
    except OSError as exc:
        die(str(exc))
    finally:
        os.close(fd)
    print(json.dumps({"present": True, "device": device, "pose": {"pan": pan_v, "tilt": tilt_v, "zoom": zoom_v}}))


def cmd_nudge(d_pan: int, d_tilt: int, d_zoom: int, fine: bool = False) -> None:
    device = find_device()
    if not device:
        die("camera not found")
    step = FINE_STEP if fine else FAST_STEP
    fd = open_device(device)
    try:
        pan = g_ctrl(fd, V4L2_CID_PAN_ABSOLUTE)
        tilt = g_ctrl(fd, V4L2_CID_TILT_ABSOLUTE)
        zoom = g_ctrl(fd, V4L2_CID_ZOOM_ABSOLUTE)
        pan = snap(pan + d_pan * step["pan"], PAN_RANGE)
        tilt = snap(tilt + d_tilt * step["tilt"], TILT_RANGE)
        zoom = snap(zoom + d_zoom * step["zoom"], ZOOM_RANGE)
        s_ext_pan_tilt(fd, pan, tilt)
        if d_zoom:
            s_ctrl(fd, V4L2_CID_ZOOM_ABSOLUTE, zoom)
    except OSError as exc:
        die(str(exc))
    finally:
        os.close(fd)
    print(json.dumps({"present": True, "device": device, "pose": {"pan": pan, "tilt": tilt, "zoom": zoom}}))


def cmd_prepare() -> None:
    device = find_device()
    if not device:
        print(json.dumps({"present": False}))
        return
    fd = open_device(device)
    try:
        mode_off(fd)
    except OSError as exc:
        die(str(exc))
    finally:
        os.close(fd)
    print(json.dumps({"present": True, "device": device}))


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
    print("usage: ptz.py device|get|prepare|set [--unlock] PAN TILT ZOOM|nudge [--fine] DPAN DTILT DZOOM|occupancy", file=sys.stderr)
    sys.exit(2)


def main(argv: list[str]) -> None:
    if len(argv) < 2:
        usage()
    cmd = argv[1]
    if cmd == "device":
        cmd_device()
    elif cmd == "get":
        cmd_get()
    elif cmd == "prepare":
        cmd_prepare()
    elif cmd == "set":
        unlock = False
        nums: list[int] = []
        for arg in argv[2:]:
            if arg == "--unlock":
                unlock = True
            else:
                nums.append(int(arg))
        if len(nums) != 3:
            usage()
        cmd_set(nums[0], nums[1], nums[2], unlock=unlock)
    elif cmd == "nudge":
        fine = False
        nums: list[int] = []
        for arg in argv[2:]:
            if arg == "--fine":
                fine = True
            else:
                nums.append(int(arg))
        if len(nums) != 3:
            usage()
        cmd_nudge(nums[0], nums[1], nums[2], fine=fine)
    elif cmd == "occupancy":
        cmd_occupancy()
    else:
        usage()


if __name__ == "__main__":
    main(sys.argv)
