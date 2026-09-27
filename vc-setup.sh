#!/bin/bash
# Eenmalige registratie van een virtuele Raumfeld Connector als KAMER in het Raumfeld-systeem op je
# netwerk — AP-loos, via de ingebouwde PreconfiguredSetupController + een gesimuleerde setup-knop.
# Het toestel neemt daarbij AUTOMATISCH het system-id van je Raumfeld-host over.
#
#   sudo bash vc-setup.sh ["Kamernaam"] [system-id]
#
# Kamernaam  (optioneel) wordt de naam van de kamer/speler in de app (standaard: Virtual Connector).
# system-id  (optioneel) alleen nodig om een specifiek systeem af te dwingen; normaal niet invullen.
set -u
TOOLS=${TOOLS:-/opt/virtualtools}
ROOT=${ROOT:-/opt/rfconnector}
ROOM="${1:-Virtual Connector}"
SYSID="${2:-}"
D="$ROOT/var/raumfeld-1.0"
LOG=/tmp/vc-master.log
[ "$(id -u)" = 0 ] || { echo "Draai als root (sudo)."; exit 1; }
waitfor(){ local pat="$1" secs="$2" i; for i in $(seq 1 "$secs"); do grep -qE "$pat" "$LOG" 2>/dev/null && return 0; sleep 1; done; return 1; }

echo "== voorbereiden (kamer '$ROOM') =="
mkdir -p "$D" "$ROOT/tmp"
sed -i '/updates.raumfeld.com/d' "$ROOT/etc/hosts" 2>/dev/null   # oude update-blokkade: laat de setup vastlopen
printf '[GLOBAL]\nrenderer-name=%s\n' "$ROOM" > "$D/renderer-config.ini"   # de setup gebruikt deze naam
printf '{ "roomName": "%s", "isHost": false, "NETWORK": { "type": "wired" } }\n' "$ROOM" > "$ROOT/tmp/raumfeld-setup.json"
[ -n "$SYSID" ] && printf '%s' "$SYSID" > "$D/system-id" && echo "  system-id afgedwongen: $SYSID"
OLDID=$(cat "$D/system-id" 2>/dev/null)
rm -f "$D/device-role.json"                                    # -> toestel gaat naar 'waiting-for-setup'

echo "== stack starten =="
bash "$TOOLS/vc-up.sh" >/dev/null 2>&1
for n in master-process renderer renderer.bin stream-decoder; do pkill -9 -x "$n" 2>/dev/null; done
sleep 2
setsid bash "$TOOLS/vc-master.sh" </dev/null >"$LOG" 2>&1 &
waitfor "waiting-for-setup" 60 || echo "  (nog geen waiting-for-setup gezien — toch doorgaan)"
sleep 5

echo "== setup-knop simuleren =="
chroot "$ROOT" /raumfeld/hardwared/hw-cli simulate-button setup pressed    >/dev/null 2>&1; sleep 1
chroot "$ROOT" /raumfeld/hardwared/hw-cli simulate-button setup long-press >/dev/null 2>&1

echo "== wachten op afronding (max. 3 min) =="
if waitfor "setup state machine finished with result: success" 180; then
  waitfor "System Id changed" 60
  NEWID=$(cat "$D/system-id" 2>/dev/null)
  echo "== KLAAR: kamer '$ROOM' geregistreerd. =="
  [ "$NEWID" != "$OLDID" ] && echo "   system-id automatisch overgenomen van je Raumfeld-host: $NEWID" \
                           || echo "   system-id: $NEWID"
  exit 0
else
  echo "!! Setup niet voltooid binnen 3 min — zie $LOG (zoek 'PreconfiguredSetupController', 'check software update')."
  exit 1
fi
