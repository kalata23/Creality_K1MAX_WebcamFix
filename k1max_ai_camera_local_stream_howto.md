# Getting the built-in AI Camera working locally on a rooted Creality K1 / K1 Max (Fluidd / Mainsail)

## The symptom

- You've rooted your K1/K1 Max and installed Fluidd/Mainsail (e.g. via the [Creality Helper Script](https://github.com/Guilouz/Creality-Helper-Script)).
- The built-in **AI Camera** works fine in the **Creality Print mobile app**, but shows nothing in:
  - Fluidd / Mainsail
  - the printer's own local web UI (`http://<printer-ip>/`)
  - Creality Print desktop
  - the Moonraker API

This writeup documents the root cause and a working fix for the newer **Ingenic T31-based** AI Camera hardware revision (USB ID `a108:2231`), which is the module later K1/K1 Max units shipped with. If your camera shows as a plain Sonix UVC device (`0c45:6366`) in `lsusb`, you have the older hardware — that one is already documented as working directly with `mjpg-streamer`'s `input_uvc` plugin; you don't need this guide.

## Why it happens

Two separate problems stack on top of each other:

**1. Nothing turns the camera's video into a normal HTTP stream.**
On this hardware, a process called `cam_app` owns the camera and grabs frames from `/dev/v4l/by-id/main-video-4`. It hands those frames off internally via a Unix domain socket at `/var/run/mjpg_main_sock` using a memfd (shared-memory file descriptor) handoff — this is a proprietary, undocumented-by-Creality mechanism, not a normal MJPEG/UVC stream. Two other processes, `webrtc` and `webrtc_local`, relay this feed to **Creality Cloud** over WebRTC — that's what the mobile app (and only the mobile app) is actually watching. Nothing locally was reading `/var/run/mjpg_main_sock` and re-serving it as HTTP, so Fluidd/Mainsail/the local web UI had nothing to point at.

**2. Even once that's fixed, the webcam config is often still broken.**
The Creality Helper Script's `moonraker.conf` template ships a `[webcam Camera]` block with a placeholder example IP (`xxx.xxx.xxx.xxx` → often left as a stale example IP) that many people forget to correct — and Fluidd's own Settings → Webcams UI can additionally have a *second*, database-stored webcam entry with the same stale-IP problem, independent of the config file one.

## The fix

You'll need root SSH access to the printer (default in recent firmware: `root` / `creality_2023`, or whatever you set).

### Step 1 — Confirm you have the same hardware

```sh
lsusb
```

Look for `ID a108:2231` (Ingenic Semiconductor HD Web Camera). If you see `0c45:6366` instead, stop here — you have the older Sonix camera and a simpler existing fix applies (see the Helper Script wiki's camera page).

Then confirm the capture process and socket exist:

```sh
ps w | grep cam_app
ls -la /var/run/mjpg_main_sock
```

You should see something like:
```
1090 root  /usr/bin/cam_app -i /dev/v4l/by-id/main-video-4 -t 0 -w 1280 -h 720 -f 15 -c
```

### Step 2 — Test a local MJPEG re-stream (no reboot, fully reversible)

The stock firmware already ships `mjpg_streamer` with an `input_memfd` plugin built specifically to read `cam_app`'s socket — it's just never invoked. Test it manually:

```sh
export LD_LIBRARY_PATH=/usr/lib/mjpg-streamer
/usr/bin/mjpg_streamer -b -i "input_memfd.so -t 0" -o "output_http.so -p 8080 -w /usr/share/mjpg-streamer/www"
```

(`-t 0` = main stream. `-b` = daemonize.)

Test it:
```sh
wget -q -O /tmp/snap.jpg 'http://127.0.0.1:8080/?action=snapshot'
```
If `/tmp/snap.jpg` is a real JPEG (starts with bytes `FF D8 FF E0`, tens of KB in size), it worked — pull it off with `scp`/`pscp` and open it to confirm.

Good news: nginx on these printers is **already** configured to proxy `/webcam/` on both Fluidd (port 4408) and Mainsail (port 4409) to `127.0.0.1:8080` — you don't need to touch nginx at all. Check:
```sh
grep -A2 'location /webcam/' /usr/data/nginx/nginx/nginx.conf
```

To undo this test at any point: `killall mjpg_streamer`. Nothing persists yet — a reboot removes it.

### Step 3 — Fix the moonraker.conf webcam URL

```sh
grep -n -A10 '\[webcam Camera\]' /usr/data/printer_data/config/moonraker.conf
```

If `stream_url`/`snapshot_url` point at some other IP than `127.0.0.1`, back up and fix it:

```sh
cp /usr/data/printer_data/config/moonraker.conf /usr/data/printer_data/config/moonraker.conf.bak
sed -i 's#http://[0-9.]*:8080#http://127.0.0.1:8080#g' /usr/data/printer_data/config/moonraker.conf
/etc/init.d/S56moonraker_service restart
```

### Step 4 — Make it survive a reboot

Create `/etc/init.d/S99zzmjpg_streamer_local` (the `zz` just makes sure it sorts after every other `S99` script, so it starts last):

```sh
#!/bin/sh
#
# Local MJPEG re-stream of the built-in AI camera for Fluidd/Mainsail/LAN access.
# Reads frames cam_app already shares via /var/run/mjpg_main_sock (memfd hand-off)
# and re-serves them as HTTP MJPEG on :8080, which nginx already proxies at /webcam/.
#
# Safe to remove entirely: rm /etc/init.d/S99zzmjpg_streamer_local && killall mjpg_streamer
#

export LD_LIBRARY_PATH=/usr/lib/mjpg-streamer

start() {
	echo "Starting local AI camera MJPEG re-stream..."
	i=0
	while [ ! -S /var/run/mjpg_main_sock ] && [ $i -lt 30 ]; do
		sleep 1
		i=$((i+1))
	done
	/usr/bin/mjpg_streamer -b -i "input_memfd.so -t 0" -o "output_http.so -p 8080 -w /usr/share/mjpg-streamer/www"
}

stop() {
	echo "Stopping local AI camera MJPEG re-stream..."
	killall mjpg_streamer 2>/dev/null
}

case "$1" in
  start)
	start
	;;
  stop)
	stop
	;;
  restart)
	stop
	sleep 1
	start
	;;
  *)
	echo "Usage: $0 {start|stop|restart}"
	exit 1
esac
```

```sh
chmod +x /etc/init.d/S99zzmjpg_streamer_local
/etc/init.d/S99zzmjpg_streamer_local start
```

The script waits (up to 30s) for `cam_app`'s socket to exist before starting, so boot ordering relative to `cam_app`/`S99start_app` doesn't matter.

Reboot to confirm it comes back on its own:
```sh
reboot
```
Wait ~30–60s, reconnect, then check `ps w | grep mjpg` and re-test the snapshot URL.

### Step 5 — Clean up any duplicate/stale webcam entry in Fluidd

Fluidd/Mainsail's Settings → Webcams may show a *second* camera entry (added earlier through that same UI) that's stored in Moonraker's database rather than `moonraker.conf`, and can carry its own stale IP independent of what you fixed in Step 3. Easiest fix: open it in **Fluidd → Settings → Webcams**, edit the Stream/Snapshot URL to a relative path:

```
/webcam/?action=stream
/webcam/?action=snapshot
```

(Relative paths are better than hardcoding an IP — they keep working even if the printer's IP changes later, since the browser resolves them against whatever host you're currently viewing Fluidd from.)

## Access URLs once done

- Fluidd: `http://<printer-ip>:4408/webcam/?action=stream`
- Mainsail: `http://<printer-ip>:4409/webcam/?action=stream`
- Raw: `http://<printer-ip>:8080/?action=stream`

## Full rollback

Nothing here touches `cam_app`, the AI spaghetti-detection pipeline, or Creality Cloud/mobile-app connectivity — it only adds a second, independent reader of a socket `cam_app` already writes to. To fully revert:

```sh
rm /etc/init.d/S99zzmjpg_streamer_local
killall mjpg_streamer
cp /usr/data/printer_data/config/moonraker.conf.bak /usr/data/printer_data/config/moonraker.conf
/etc/init.d/S56moonraker_service restart
```

## Note on Creality Print *desktop*

Getting this working locally does **not** fix the K1/K1 Max camera panel inside the Creality Print **desktop** app — that's a separate, widely-reported issue ("the device bound to the Creality Cloud does not support video yet") affecting the desktop client specifically, unrelated to your local network. The mobile app and this local stream both work regardless — just open the raw stream URL above directly in a browser instead of relying on desktop Creality Print's camera tab.

---
*Diagnosed and tested on a K1 Max running the Creality Helper Script (Fluidd + Moonraker), Ingenic T31 AI Camera hardware (`lsusb` ID `a108:2231`), firmware/BusyBox dated June 2026. Camera hardware and internal socket names should be identical across other K1-series printers with the same camera module, but always confirm Step 1 before proceeding.*
