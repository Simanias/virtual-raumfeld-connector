#!/bin/bash
# Eenmalige provisioning van een virtuele Raumfeld Connector: registreer dit toestel als KAMER
# in een bestaand Raumfeld-systeem — AP-loos, via de ingebouwde PreconfiguredSetupController +
# een gesimuleerde setup-knop. Daarna boot het toestel als geconfigureerde renderer (systemd).
#
#   sudo bash vc-setup.sh "<Kamernaam>" <system-id>
#
# <system-id>  = de systeem-UUID van je Raumfeld-systeem. Te vinden op een bestaand toestel in
#                /var/raumfeld-1.0/system-id, of via de host. Zonder dit rolt het toestel niet
#                het juiste systeem in. (Weglaten = huidige/gegenereerde system-id behouden.)
set -u
TOOLS=${TOOLS:-/opt/virtualtools}
ROOT=${ROOT:-/opt/rfconnector}
ROOM="${1:?Gebruik: vc-setup.sh \"Kamernaam\" <system-id>}"
SYSID="${2:-}"
D="$ROOT/var/raumfeld-1.0"
[ "$(id -u)" = 0 ] || { echo "Draai als root (sudo)."; exit 1; }

echo "== stack starten =="
bash "$TOOLS/vc-up.sh"
sleep 18

echo "== provisioning voorbereiden (kamer '$ROOM') =="
mkdir -p "$D" "$ROOT/tmp"
[ -n "$SYSID" ] && printf '%s' "$SYSID" > "$D/system-id" && echo "  system-id gezet op $SYSID"
printf '{ "roomName": "%s", "isHost": false, "NETWORK": { "type": "wired" } }\n' "$ROOM" > "$ROOT/tmp/raumfeld-setup.json"
rm -f "$D/device-role.json"     # -> toestel gaat naar 'waiting-for-setup'

echo "== master-process herstarten (waiting-for-setup) =="
for n in master-process renderer stream-decoder; do pkill -9 -x "$n" 2>/dev/null; done
sleep 2
setsid bash "$TOOLS/vc-master.sh" </dev/null >/tmp/vc-master.log 2>&1 &
sleep 15

echo "== setup-knop simuleren (start PreconfiguredSetupController + SimulatedCalloutServer) =="
chroot "$ROOT" /raumfeld/hardwared/hw-cli simulate-button setup pressed 2>/dev/null; sleep 1
chroot "$ROOT" /raumfeld/hardwared/hw-cli simulate-button setup long-press 2>/dev/null
sleep 25

if grep -q "setup state machine finished with result: success" /tmp/vc-master.log 2>/dev/null; then
  echo "== KLAAR: setup geslaagd. Kamer '$ROOM' is in het Raumfeld-systeem geregistreerd. =="
  echo "   Herstart de renderer-stack schoon:  sudo systemctl restart vc-connector"
else
  echo "!! Setup lijkt niet voltooid — check /tmp/vc-master.log (zoek 'PreconfiguredSetupController' / 'no wifi present')."
fi
