# Insta360 Link

Omarchy bar plugin for an Insta360 Link webcam. Icon in the bar, PTZ pad in the popout, three presets, auto-restore when another app starts video, park when it stops.

Works with the original Link (`2e1a:4c01`) as a UVC device. No vendor SDK.

## Install

```sh
omarchy plugin add /home/dave/Documents/GitHub/Insta360Link --enable --yes
```

Or any git remote of this repo. Then:

```sh
omarchy bar move dave.insta360-link --section right
```

Needs `v4l2-ctl` (`v4l-utils`) and `python3`. Both are already on a stock Omarchy box.

## Use

- Click the camera icon for the panel. Right-click parks.
- Preview is off until you toggle it. Close the panel and it drops the stream so Zoom/OBS can take the camera.
- Click a preset tab to move there. Nudge with the pad or arrow keys. Changes write back into that preset after a short pause.
- Double-click a tab to rename. Right-click a tab (or press `d`) to mark it as the default for the next video session.
- `1` `2` `3` select presets. `p` toggles preview. `+` / `-` zoom. Park button looks down. Right-click Park stores the current pose as the hangup pose.

When Firefox, Chrome, Zoom, Discord, or OBS starts video, the starred preset is applied. When that video session ends, the camera parks.

## Config

`~/.config/omarchy/ptz.json` is created on first save. Three presets, which one is default, optional park pose.

Debug the helper without the shell:

```sh
python3 ptz.py occupancy
python3 ptz.py get
python3 ptz.py set 0 0 100
```

## Remove

```sh
omarchy plugin remove dave.insta360-link
```
