#!/bin/bash
# One-time registration of a Virtual Raumfeld Connector as a ROOM in the Raumfeld system on your
# network — without the setup access point, via the built-in PreconfiguredSetupController + a
# simulated setup button. The device AUTOMATICALLY adopts the system-id of your Raumfeld host.
#
#   sudo bash vc-setup.sh ["Room name"] [system-id]
#
# Room name  (optional) becomes the name of the room/player in the app (default: Virtual Connector).
# system-id  (optional) only needed to force a specific system; normally leave it out.
set -u
TOOLS=${TOOLS:-/opt/virtualtools}
ROOT=${ROOT:-/opt/rfconnector}
ROOM="${1:-Virtual Connector}"
SYSID="${2:-}"
D="$ROOT/var/raumfeld-1.0"
LOG=/tmp/vc-master.log
[ "$(id -u)" = 0 ] || { echo "Run as root (sudo)."; exit 1; }
waitfor(){ local pat="$1" secs="$2" i; for i in $(seq 1 "$secs"); do grep -qE "$pat" "$LOG" 2>/dev/null && return 0; sleep 1; done; return 1; }

echo "== preparing (room '$ROOM') =="
mkdir -p "$D" "$ROOT/tmp"
sed -i '/updates.raumfeld.com/d' "$ROOT/etc/hosts" 2>/dev/null   # old update block: makes the setup hang
printf '[GLOBAL]\nrenderer-name=%s\n' "$ROOM" > "$D/renderer-config.ini"
# the PreconfiguredSetupController reads the keys name / isHost / ssid / password / psk ('name' = room name)
python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1], "isHost": False}))' "$ROOM" > "$ROOT/tmp/raumfeld-setup.json"
[ -n "$SYSID" ] && printf '%s' "$SYSID" > "$D/system-id" && echo "  system-id forced: $SYSID"
OLDID=$(cat "$D/system-id" 2>/dev/null)
rm -f "$D/device-role.json"                                    # -> device goes to 'waiting-for-setup'

echo "== starting the stack =="
bash "$TOOLS/vc-up.sh" >/dev/null 2>&1
for n in master-process renderer renderer.bin stream-decoder; do pkill -9 -x "$n" 2>/dev/null; done
sleep 2
setsid bash "$TOOLS/vc-master.sh" </dev/null >"$LOG" 2>&1 &
waitfor "waiting-for-setup" 60 || echo "  (no waiting-for-setup seen yet — continuing anyway)"
sleep 5

echo "== simulating the setup button =="
chroot "$ROOT" /raumfeld/hardwared/hw-cli simulate-button setup pressed    >/dev/null 2>&1; sleep 1
chroot "$ROOT" /raumfeld/hardwared/hw-cli simulate-button setup long-press >/dev/null 2>&1

echo "== waiting for completion (max. 3 min) =="
if waitfor "setup state machine finished with result: success" 180; then
  waitfor "System Id changed" 60
  NEWID=$(cat "$D/system-id" 2>/dev/null)
  echo "== DONE: room '$ROOM' registered. =="
  [ "$NEWID" != "$OLDID" ] && echo "   system-id adopted automatically from your Raumfeld host: $NEWID" \
                           || echo "   system-id: $NEWID"
  exit 0
else
  echo "!! Setup did not finish within 3 min — see $LOG (look for 'PreconfiguredSetupController', 'check software update')."
  exit 1
fi
