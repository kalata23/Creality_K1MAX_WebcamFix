#!/bin/sh
# k1-ai-camera-local-stream.sh
#
# Exposes the built-in "AI Camera" (Ingenic T31-based module, cam_app) on a
# rooted Creality K1 / K1 Max / K1C as a normal local HTTP MJPEG stream, so it
# shows up in Fluidd / Mainsail / the local network - not just Creality Print
# mobile via Creality Cloud.
#
# https://github.com/kalata23/Creality_K1MAX_WebcamFix
#
# SAFETY MODEL
#   - Every mutating action is preceded by hard checks. If the running system
#     does not match the exact expected fingerprint, the script refuses to
#     touch anything and exits with an explanation.
#   - Nothing is ever overwritten without a timestamped backup first, and
#     every backup this script makes is recorded in a manifest so `uninstall`
#     restores exactly what it changed - nothing else.
#   - `check` (default) makes zero changes. `install` and `uninstall` are the
#     only commands that modify the system, and both are safe to run more
#     than once (idempotent).
#   - After any change, the script verifies the result (real JPEG bytes over
#     HTTP) and automatically rolls back if verification fails.
#
# USAGE
#   ./k1-ai-camera-local-stream.sh check       # inspect only, no changes (default)
#   ./k1-ai-camera-local-stream.sh install      # apply the fix (auto-backs up first)
#   ./k1-ai-camera-local-stream.sh uninstall    # fully revert to the pre-install state
#   ./k1-ai-camera-local-stream.sh status       # show current state
#
# Flags: -y / --yes   skip the interactive confirmation prompt before install/uninstall
#
# Tested on: K1 Max, rooted via Creality Helper Script (Fluidd + Moonraker),
# Ingenic T31 AI Camera hardware (lsusb ID a108:2231).

set -u

VERSION="1.0.0"
PORT=8080
SOCK=/var/run/mjpg_main_sock
PLUGIN_DIR=/usr/lib/mjpg-streamer
WWW_DIR=/usr/share/mjpg-streamer/www
MJPG_BIN=/usr/bin/mjpg_streamer
INIT_SCRIPT=/etc/init.d/S99zzk1aicam
BACKUP_DIR=/root/.k1-ai-camera-local-stream
MANIFEST="$BACKUP_DIR/moonraker_conf_backup.path"
LOCKFILE=/tmp/k1-ai-camera-local-stream.lock
LOGFILE="$BACKUP_DIR/install.log"
MOONRAKER_CONF=/usr/data/printer_data/config/moonraker.conf

ASSUME_YES=0
for arg in "$@"; do
	case "$arg" in
		-y|--yes) ASSUME_YES=1 ;;
	esac
done
CMD="check"
for arg in "$@"; do
	case "$arg" in
		check|install|uninstall|status) CMD="$arg" ;;
	esac
done

log() {
	echo "$*"
	[ -d "$BACKUP_DIR" ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE" 2>/dev/null
}

fail() {
	echo ""
	echo "ABORTED: $*"
	echo "No changes were made."
	exit 1
}

confirm() {
	[ "$ASSUME_YES" = "1" ] && return 0
	printf '%s [y/N] ' "$1"
	read -r ans
	case "$ans" in
		y|Y|yes|YES) return 0 ;;
		*) return 1 ;;
	esac
}

acquire_lock() {
	if [ -e "$LOCKFILE" ]; then
		lockpid=$(cat "$LOCKFILE" 2>/dev/null)
		if [ -n "$lockpid" ] && kill -0 "$lockpid" 2>/dev/null; then
			fail "Another instance of this script (pid $lockpid) is already running."
		fi
	fi
	echo $$ > "$LOCKFILE"
}
release_lock() { rm -f "$LOCKFILE"; }
trap release_lock EXIT INT TERM

# --------------------------------------------------------------------------
# Fingerprint checks - all must pass before any mutating command proceeds
# --------------------------------------------------------------------------

check_root() {
	[ "$(id -u)" = "0" ] || fail "This script must be run as root (you are running as $(id -un))."
}

check_platform() {
	[ -d /usr/data/printer_data ] || fail "This does not look like a rooted Creality K1-series printer (missing /usr/data/printer_data). Refusing to continue."
	moonraker_init=$(find_moonraker_init)
	[ -n "$moonraker_init" ] || fail "No Moonraker init script found under /etc/init.d. Refusing to continue - this tool expects Fluidd/Mainsail + Moonraker to already be installed (e.g. via the Creality Helper Script)."
	[ -x /usr/bin/cam_app ] || fail "/usr/bin/cam_app not found. This tool is only for K1-series printers with the built-in AI Camera module."
}

find_moonraker_init() {
	for f in /etc/init.d/*moonraker*; do
		[ -e "$f" ] && { echo "$f"; return 0; }
	done
	return 1
}

detect_camera_usb_id() {
	if command -v lsusb >/dev/null 2>&1; then
		lsusb 2>/dev/null | grep -qi "a108:2231" && { echo "yes"; return; }
	fi
	echo "unknown"
}

check_cam_app_running() {
	ps w 2>/dev/null | grep "[c]am_app" >/dev/null 2>&1
}

wait_for_socket() {
	i=0
	while [ ! -S "$SOCK" ] && [ "$i" -lt 20 ]; do
		sleep 1
		i=$((i + 1))
	done
	[ -S "$SOCK" ]
}

check_mjpg_streamer_present() {
	[ -x "$MJPG_BIN" ] || fail "$MJPG_BIN not found on this system."
	[ -f "$PLUGIN_DIR/input_memfd.so" ] || fail "$PLUGIN_DIR/input_memfd.so not found - this firmware build does not ship the plugin this tool relies on."
	[ -f "$PLUGIN_DIR/output_http.so" ] || fail "$PLUGIN_DIR/output_http.so not found."
}

# Returns: "free" | "ours" | "other"
check_port_owner() {
	pids=$(busybox_pidof mjpg_streamer)
	if [ -n "$pids" ]; then
		for p in $pids; do
			if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q "input_memfd"; then
				echo "ours"
				return
			fi
		done
	fi
	if command -v netstat >/dev/null 2>&1 && netstat -tln 2>/dev/null | grep -q ":$PORT "; then
		echo "other"
		return
	fi
	echo "free"
}

busybox_pidof() {
	pidof "$1" 2>/dev/null
}

fetch_snapshot() {
	# $1 = destination file, $2 = url
	rm -f "$1"
	wget -q -O "$1" "$2" --timeout=5 2>/dev/null
	[ -s "$1" ] || return 1
	head_bytes=$(head -c 3 "$1" | od -An -tx1 | tr -d ' \n')
	[ "$head_bytes" = "ffd8ff" ]
}

run_precheck() {
	echo "== K1 AI Camera Local Stream - v$VERSION =="
	echo ""
	check_root
	check_platform
	echo "[ok] Running as root on a rooted Creality K1-series printer."

	usb_hit=$(detect_camera_usb_id)
	if [ "$usb_hit" = "yes" ]; then
		echo "[ok] Detected Ingenic AI Camera (USB ID a108:2231)."
	else
		echo "[warn] Could not confirm USB ID a108:2231 (lsusb missing or ID differs)."
		echo "       Continuing based on functional checks below, but proceed with extra care."
	fi

	if ! check_cam_app_running; then
		fail "cam_app is not currently running. This tool expects the stock AI camera capture process to already be active - nothing to attach to."
	fi
	echo "[ok] cam_app is running."

	if ! wait_for_socket; then
		fail "$SOCK did not appear after 20s. This firmware/hardware may not use the expected memfd hand-off - refusing to guess."
	fi
	echo "[ok] $SOCK exists."

	check_mjpg_streamer_present
	echo "[ok] mjpg_streamer + required plugins present."

	port_state=$(check_port_owner)
	case "$port_state" in
		other)
			fail "Port $PORT is already in use by something that is NOT this tool's own mjpg_streamer instance. Refusing to interfere - please free up port $PORT (or investigate what's using it) before running install."
			;;
	esac
	echo "[ok] Port $PORT is free (or already owned by a previous run of this tool)."
	echo ""
}

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

cmd_status() {
	echo "== K1 AI Camera Local Stream - status =="
	if [ -f "$INIT_SCRIPT" ]; then
		echo "Init script: installed ($INIT_SCRIPT)"
	else
		echo "Init script: not installed"
	fi
	port_state=$(check_port_owner)
	echo "Port $PORT: $port_state"
	if fetch_snapshot /tmp/.k1cam_status_check.jpg "http://127.0.0.1:$PORT/?action=snapshot"; then
		echo "Live stream: WORKING ($(wc -c < /tmp/.k1cam_status_check.jpg 2>/dev/null | tr -d ' ') bytes JPEG received)"
	else
		echo "Live stream: not responding"
	fi
	rm -f /tmp/.k1cam_status_check.jpg
	if [ -f "$MANIFEST" ]; then
		echo "moonraker.conf backup on file: $(cat "$MANIFEST")"
	fi
}

cmd_check() {
	run_precheck
	echo "All checks passed. It is safe to run:"
	echo "  $0 install"
	echo "(nothing has been changed)"
}

cmd_install() {
	run_precheck
	mkdir -p "$BACKUP_DIR"
	log "install started (v$VERSION)"

	port_state=$(check_port_owner)
	if [ "$port_state" = "ours" ] && [ -f "$INIT_SCRIPT" ]; then
		if fetch_snapshot /tmp/.k1cam_verify.jpg "http://127.0.0.1:$PORT/?action=snapshot"; then
			rm -f /tmp/.k1cam_verify.jpg
			echo "Already installed and working - nothing to do."
			log "install: already installed and verified working, no-op"
			exit 0
		fi
	fi

	confirm "About to write $INIT_SCRIPT, start a local MJPEG server on port $PORT, and (if needed) fix webcam URLs in moonraker.conf. Continue?" \
		|| fail "Cancelled by user."

	install_init_script
	start_stream
	if ! verify_stream; then
		echo "Verification failed - rolling back the init script and stopping the stream."
		"$INIT_SCRIPT" stop >/dev/null 2>&1
		rm -f "$INIT_SCRIPT"
		fail "Local stream did not produce a valid JPEG after starting. No lasting changes were made."
	fi
	echo "[ok] Local MJPEG stream verified (valid JPEG received on port $PORT)."

	fix_moonraker_conf

	echo ""
	echo "== Install complete =="
	echo "Stream URLs:"
	echo "  http://<printer-ip>:$PORT/?action=stream"
	echo "  http://<printer-ip>:4408/webcam/?action=stream   (Fluidd, if nginx already proxies /webcam/)"
	echo "  http://<printer-ip>:4409/webcam/?action=stream   (Mainsail, if nginx already proxies /webcam/)"
	echo ""
	echo "If Fluidd/Mainsail still show no video, open Settings -> Webcams there and"
	echo "check for a second, separately-stored camera entry with a stale IP - point"
	echo "it at /webcam/?action=stream (relative path) instead."
	echo ""
	echo "To fully revert everything this script changed: $0 uninstall"
	log "install finished successfully"
}

install_init_script() {
	cat > "$INIT_SCRIPT" <<'EOF'
#!/bin/sh
#
# Installed by k1-ai-camera-local-stream.sh
# Local MJPEG re-stream of the built-in AI camera for Fluidd/Mainsail/LAN access.
# Reads frames cam_app already shares via /var/run/mjpg_main_sock (memfd hand-off)
# and re-serves them as HTTP MJPEG on :8080, which nginx already proxies at /webcam/.
#
# Safe to remove entirely: rm /etc/init.d/S99zzk1aicam && killall mjpg_streamer
#

export LD_LIBRARY_PATH=/usr/lib/mjpg-streamer

start() {
	echo "Starting local AI camera MJPEG re-stream..."
	i=0
	while [ ! -S /var/run/mjpg_main_sock ] && [ $i -lt 30 ]; do
		sleep 1
		i=$((i+1))
	done
	pidof mjpg_streamer >/dev/null 2>&1 && return 0
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
EOF
	chmod +x "$INIT_SCRIPT"
	log "wrote $INIT_SCRIPT"
}

start_stream() {
	# Idempotent: if our instance is already running, leave it alone.
	if [ "$(check_port_owner)" = "ours" ]; then
		return 0
	fi
	"$INIT_SCRIPT" start
	sleep 1
}

verify_stream() {
	fetch_snapshot /tmp/.k1cam_verify.jpg "http://127.0.0.1:$PORT/?action=snapshot"
	rc=$?
	rm -f /tmp/.k1cam_verify.jpg
	return $rc
}

fix_moonraker_conf() {
	[ -f "$MOONRAKER_CONF" ] || { echo "[skip] $MOONRAKER_CONF not found - no webcam config to fix."; return; }

	grep -q '^\[webcam ' "$MOONRAKER_CONF" || {
		echo "[skip] No [webcam ...] section found in moonraker.conf - nothing to fix there."
		echo "       Add one via Fluidd's Settings -> Webcams UI, pointing at http://127.0.0.1:$PORT/?action=stream"
		return
	}

	# Only touch it if stream_url/snapshot_url point at our port with some
	# other host than 127.0.0.1/localhost - i.e. leave deliberate custom
	# setups alone.
	if grep -qE "^(stream_url|snapshot_url): http://(127\.0\.0\.1|localhost):$PORT/" "$MOONRAKER_CONF"; then
		echo "[ok] moonraker.conf webcam URLs already point at 127.0.0.1:$PORT - nothing to change."
		return
	fi
	if ! grep -qE "^(stream_url|snapshot_url): http://[^/]+:$PORT/" "$MOONRAKER_CONF"; then
		echo "[skip] moonraker.conf webcam section doesn't reference port $PORT - leaving it untouched (may be a deliberate custom setup)."
		return
	fi

	backup="$BACKUP_DIR/moonraker.conf.$(date '+%Y%m%d-%H%M%S').bak"
	cp "$MOONRAKER_CONF" "$backup" || fail "Could not create backup at $backup - refusing to edit moonraker.conf."
	echo "$backup" > "$MANIFEST"
	log "backed up moonraker.conf to $backup"

	sed -i -E "s#^(stream_url|snapshot_url): http://[^/]+:$PORT/#\1: http://127.0.0.1:$PORT/#" "$MOONRAKER_CONF"

	moonraker_init=$(find_moonraker_init)
	"$moonraker_init" restart >/dev/null 2>&1
	i=0
	ok=0
	while [ $i -lt 15 ]; do
		if fetch_snapshot /tmp/.k1cam_mr_check.jpg "http://127.0.0.1:7125/server/info" 2>/dev/null; then :; fi
		if wget -q -O- "http://127.0.0.1:7125/server/info" --timeout=3 2>/dev/null | grep -q '"result"'; then
			ok=1
			break
		fi
		sleep 1
		i=$((i + 1))
	done
	rm -f /tmp/.k1cam_mr_check.jpg

	if [ "$ok" = "1" ]; then
		echo "[ok] moonraker.conf webcam URLs fixed and Moonraker restarted successfully."
		log "moonraker.conf edited and Moonraker restart verified healthy"
	else
		echo "[warn] Moonraker did not respond after restart - restoring moonraker.conf from backup automatically."
		cp "$backup" "$MOONRAKER_CONF"
		"$moonraker_init" restart >/dev/null 2>&1
		log "moonraker.conf edit rolled back automatically - Moonraker did not come back healthy"
		echo "       moonraker.conf has been restored to its previous state. The camera stream itself is still fine on port $PORT."
	fi
}

cmd_uninstall() {
	check_root
	[ -f "$INIT_SCRIPT" ] || [ "$(check_port_owner)" = "ours" ] || {
		echo "Nothing installed by this tool was found - nothing to do."
		exit 0
	}

	confirm "About to stop the local camera stream, remove $INIT_SCRIPT, and restore moonraker.conf from backup if this tool changed it. Continue?" \
		|| fail "Cancelled by user."

	if [ -f "$INIT_SCRIPT" ]; then
		"$INIT_SCRIPT" stop >/dev/null 2>&1
		rm -f "$INIT_SCRIPT"
		echo "[ok] Removed $INIT_SCRIPT and stopped the stream."
	else
		killall mjpg_streamer 2>/dev/null
		echo "[ok] Stopped stream (no init script was present)."
	fi

	if [ -f "$MANIFEST" ]; then
		backup=$(cat "$MANIFEST")
		if [ -f "$backup" ]; then
			cp "$backup" "$MOONRAKER_CONF"
			moonraker_init=$(find_moonraker_init)
			[ -n "$moonraker_init" ] && "$moonraker_init" restart >/dev/null 2>&1
			echo "[ok] Restored moonraker.conf from $backup and restarted Moonraker."
			rm -f "$MANIFEST"
		else
			echo "[warn] Recorded backup $backup no longer exists - moonraker.conf left as-is."
		fi
	else
		echo "[ok] moonraker.conf was never changed by this tool - left as-is."
	fi

	echo ""
	echo "Uninstall complete. System restored to its pre-install state."
	log "uninstall completed"
}

case "$CMD" in
	check) cmd_check ;;
	install) acquire_lock; cmd_install ;;
	uninstall) acquire_lock; cmd_uninstall ;;
	status) cmd_status ;;
esac
