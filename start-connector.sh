#!/bin/bash
# Start een VIRTUELE Raumfeld Connector 2 vanuit de uitgepakte rootfs (chroot), via het
# INGEBOUWDE virtualisatie-mechanisme van de firmware.
#
#   sudo ROOT=/opt/rfconnector ALSADEV=hw:0 ./start-connector.sh
#
# Kern: RAUMFELD_VIRTUALISED_HARDWARE_ID=9 (Connector 2) -> raumfeld_is_virtualised_environment()
# = true -> hardwared draait met de "legacy/virtual hardware handler" (geen MCU/STA350/GPIO),
# genereert een UDN en verleent audio-resources. Geen hardware-stubbing nodig.
#
# Hardware-IDs (uit de firmware-manifesten): 9=Raumfeld Connector 2, 13=One S.
set -u
ROOT=${ROOT:-/opt/rfconnector}
HWID=${HWID:-9}                    # 9 = Raumfeld Connector 2
ALSADEV=${ALSADEV:-hw:0}          # jouw Pi-DAC (check: aplay -l)

[ "$(id -u)" = 0 ] || { echo "Draai als root (sudo)."; exit 1; }
[ -d "$ROOT/raumfeld" ] || { echo "rootfs niet in $ROOT (pak connector-rootfs.tar daar uit)"; exit 1; }

echo "== 1) pseudo-filesystems mounten =="
for m in proc sys dev dev/pts run var/run tmp; do mkdir -p "$ROOT/$m"; done
mountpoint -q "$ROOT/proc" || mount -t proc  proc  "$ROOT/proc"
mountpoint -q "$ROOT/sys"  || mount -t sysfs sys   "$ROOT/sys"
mountpoint -q "$ROOT/dev"  || mount --rbind /dev   "$ROOT/dev"
mountpoint -q "$ROOT/run"  || mount -t tmpfs tmpfs "$ROOT/run"

echo "== 2) DNS + ALSA -> Pi-DAC ($ALSADEV) =="
cp -f /etc/resolv.conf "$ROOT/etc/resolv.conf" 2>/dev/null || true
cat > "$ROOT/etc/asound.conf" <<EOF
pcm.!default { type plug; slave.pcm "$ALSADEV" }
ctl.!default { type hw; card ${ALSADEV#hw:} }
EOF

echo "== 3) services starten in de chroot (virtuele modus, HWID=$HWID) =="
chroot "$ROOT" /usr/bin/env -i \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  RAUMFELD_VIRTUALISED_HARDWARE_ID="$HWID" \
  RAUMFELD_LOG_TARGET=buffers \
  G_FILENAME_ENCODING="UTF-8,ISO-8859-1" \
  /bin/sh -lc '
    echo "-- system dbus --"; /etc/init.d/S30dbus start         2>&1 | tail -2
    echo "-- avahi --";       /etc/init.d/S50avahi-daemon start 2>&1 | tail -2
    echo "-- hardwared (virtueel) --"
    /etc/init.d/S85hardwared start 2>&1 | tail -3
    sleep 2
    echo "-- master-process (start renderer + streamcastd) --"
    /etc/init.d/S99master-process start 2>&1 | tail -3
  '
echo
echo "== gestart. Controleer: =="
echo "   chroot $ROOT ps w | grep -E 'hardwared|renderer|streamcastd|master-process'"
echo "   chroot $ROOT sh -lc 'tail -n 40 /var/log/messages 2>/dev/null'   # of de logger-output"
cat <<'NOTE'

STATUS / itereer-punten:
 * hardwared draait virtueel (bevestigd): legacy handler, UDN, ResourceLock grant.
 * renderer/streamcastd hebben needsAudioHardware=true -> op de Pi levert je DAC (hw:0) dat.
   In virtuele modus meldt hardwared audio als beschikbaar; verifieer dat de renderer 'hw:0' opent.
 * Discovery: de renderer kondigt zich via OpenHome/UPnP aan met de gegenereerde UDN.
   Test of de Raumfeld-app 'm ziet (moet op hetzelfde LAN; daarom Pi i.p.v. Docker-op-Mac).
NOTE
