# Creality K1 Max Webcam Fix

[github.com/kalata23/Creality_K1MAX_WebcamFix](https://github.com/kalata23/Creality_K1MAX_WebcamFix)

Get the built-in **AI Camera** on a rooted Creality K1 / K1 Max / K1C showing up locally in **Fluidd, Mainsail, and the local network** - not just inside the Creality Print mobile app via Creality Cloud.

## The problem this fixes

If you've rooted your K1-series printer and installed Fluidd/Mainsail (e.g. via the [Creality Helper Script](https://github.com/Guilouz/Creality-Helper-Script)):

- The AI Camera works fine in the **Creality Print mobile app**.
- It shows **nothing** in Fluidd, Mainsail, the printer's own local web UI, the Moonraker API, or Creality Print desktop.

This affects the newer **Ingenic T31-based** AI Camera module (`lsusb` shows `ID a108:2231`). If your `lsusb` instead shows `0c45:6366` (Sonix), you have the older camera hardware - that one already works with `mjpg-streamer`'s standard UVC plugin; this repo doesn't apply to you.

**Root cause**, in short: the camera's capture process (`cam_app`) hands frames off internally over a Unix socket (`/var/run/mjpg_main_sock`) that only Creality's own cloud-relay processes read from. Nothing locally turns that into a normal HTTP stream - and even once you fix that, the Helper Script's `moonraker.conf` template often still has a placeholder IP that was never corrected. See [`k1max_ai_camera_local_stream_howto.md`](./k1max_ai_camera_local_stream_howto.md) in this repo for the full technical writeup.

## Quick start

SSH into your printer as root, then:

```sh
wget -O k1-ai-camera-local-stream.sh https://raw.githubusercontent.com/kalata23/Creality_K1MAX_WebcamFix/main/k1-ai-camera-local-stream.sh
chmod +x k1-ai-camera-local-stream.sh
./k1-ai-camera-local-stream.sh check      # dry-run: verifies your printer matches, changes nothing
./k1-ai-camera-local-stream.sh install    # applies the fix (auto-backs up first)
```

Then open:
```
http://<your-printer-ip>:8080/?action=stream
http://<your-printer-ip>:4408/webcam/?action=stream   (Fluidd)
http://<your-printer-ip>:4409/webcam/?action=stream   (Mainsail)
```

If Fluidd/Mainsail still shows nothing, check **Settings -> Webcams** there for a second camera entry stored separately (added earlier through that same UI) that might have its own stale IP - point it at `/webcam/?action=stream` (a relative path, so it keeps working even if the printer's IP changes later).

## Undo

```sh
./k1-ai-camera-local-stream.sh uninstall
```

This removes the init script, stops the stream, and restores `moonraker.conf` from the backup the `install` step made automatically - putting the printer back exactly as it was.

## Why this is safe to run

- **`check` (default command) never changes anything** - it only verifies your printer matches the expected setup.
- `install` and `uninstall` are both **idempotent** - safe to run more than once. Re-running `install` on an already-working setup just confirms it and exits, no duplicate processes or edits.
- Every mutating step is gated behind hard checks (root shell, expected Creality file layout, `cam_app` actually running, the expected socket present, the required `mjpg_streamer` plugins present, port 8080 not already used by something unrelated). If any check fails, the script aborts immediately with an explanation and **makes zero changes**.
- `moonraker.conf` is only ever touched if it contains a `[webcam ...]` section whose URLs point at port 8080 on some host other than `127.0.0.1` - if you've already customized it differently, the script leaves it alone. A timestamped backup is made before any edit, and its path is recorded so `uninstall` restores exactly that file.
- After installing, the script fetches a real snapshot and verifies it's a valid JPEG before declaring success. If Moonraker doesn't come back healthy after a config change, **it automatically restores the backup and restarts Moonraker again** - no manual recovery needed.
- Nothing here touches `cam_app`, the AI spaghetti-detection pipeline, or your Creality Cloud/mobile app connectivity - it only adds a second, independent reader of a socket `cam_app` already writes to, plus one new init script.

Tested by installing, verifying, fully uninstalling (with independent verification the system was back to its exact original state), and reinstalling on a real K1 Max before publishing this.

## Requirements

- A rooted K1 / K1 Max / K1C with root SSH access.
- Fluidd/Mainsail + Moonraker already installed (e.g. via the Creality Helper Script).
- The Ingenic T31 AI Camera hardware revision (`lsusb` shows `a108:2231`).

## Credits / background

This resolves the scenario described as unsolved in [Guilouz/Creality-Helper-Script-Wiki discussion #444](https://github.com/Guilouz/Creality-Helper-Script-Wiki/discussions/444) ("Camera Settings Control for K1 Max with new hardware version").


