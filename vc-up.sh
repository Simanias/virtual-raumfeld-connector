#!/bin/bash
# Breng de VIRTUELE Raumfeld Connector op de Pi omhoog — chroot + ConnMan dbus-stub.
# Raakt wlan0 NIET aan (echte connmand is onschadelijk gemaakt; stub levert alleen dbus).
# Gebruik:  sudo bash /tmp/vc-up.sh
set -u
TOOLS=${TOOLS:-/opt/virtualtools}      # systeembrede locatie van deze tools
ROOT=${ROOT:-/opt/rfconnector}
HWID=9                                  # 9 = Raumfeld Connector 2
# DAC autodetecteren: eerste playback-kaart-header die geen HDMI/vc4 is; overschrijf met ALSADEV=hw:N
if [ -z "${ALSADEV:-}" ]; then
  CARDNR=$(aplay -l 2>/dev/null | awk '/^card [0-9]+:/{num=$2; sub(/:.*/,"",num); if (tolower($0) !~ /hdmi|vc4/){print num; exit}}')
  ALSADEV="hw:${CARDNR:-1}"
fi
SOCK="$ROOT/run/dbus/system_bus_socket"
STUB=$TOOLS/connman-stub.py; [ -f "$STUB" ] || STUB=/tmp/connman-stub.py
MLOG=/tmp/vc-master.log
PATHV=/usr/sbin:/usr/bin:/sbin:/bin
say(){ echo "== $* =="; }

[ "$(id -u)" = 0 ] || { echo "Draai als root (sudo)."; exit 1; }

# --- netwerkgegevens auto-detecteren (voor de stub) ---
IFACE=$(ip route | awk '/^default/{print $5; exit}')
IPCIDR=$(ip -4 -o addr show "$IFACE" | awk '{print $4; exit}')
export VC_IFACE="$IFACE"
export VC_IP="${IPCIDR%/*}"
export VC_MAC="$(cat /sys/class/net/$IFACE/address)"
export VC_GW="$(ip route | awk '/^default/{print $3; exit}')"
export VC_NETMASK="$(python3 -c 'import ipaddress,sys;print(ipaddress.IPv4Network("0.0.0.0/"+sys.argv[1]).netmask)' "${IPCIDR#*/}")"
echo "  net: $VC_IFACE $VC_IP/$VC_NETMASK gw $VC_GW mac $VC_MAC"

say "1) pseudo-fs mounten"
for m in proc sys dev dev/pts run tmp; do mkdir -p "$ROOT/$m"; done
mountpoint -q "$ROOT/proc" || mount -t proc  proc  "$ROOT/proc"
mountpoint -q "$ROOT/sys"  || mount -t sysfs sys   "$ROOT/sys"
if ! mountpoint -q "$ROOT/dev"; then
  mount --rbind /dev "$ROOT/dev"
  # rslave: losmaken van de chroot-/dev mag NOOIT de host-/dev raken (anders valt de Pi eruit)
  mount --make-rslave "$ROOT/dev" 2>/dev/null || true
fi
mountpoint -q "$ROOT/run"  || mount -t tmpfs tmpfs "$ROOT/run"

say "2) connmand onschadelijk (wlan0 blijft met rust)"
[ -e "$ROOT/usr/sbin/connmand" ] && mv "$ROOT/usr/sbin/connmand" "$ROOT/usr/sbin/connmand.real" && echo "  hernoemd" || echo "  al onschadelijk"

say "3) ALSA default -> $ALSADEV"
cp -f /etc/resolv.conf "$ROOT/etc/resolv.conf" 2>/dev/null || true
cat > "$ROOT/etc/asound.conf" <<EOF
pcm.!default { type plug; slave.pcm "$ALSADEV" }
ctl.!default { type hw; card ${ALSADEV#hw:} }
EOF

say "4) oude Raumfeld-processen opruimen (voorkomt poort-8888-conflict)"
for n in master-process renderer stream-decoder streamcastd config-service meta-server gc4a; do pkill -9 -x "$n" 2>/dev/null; done
sleep 1

say "5) system-dbus + avahi + hardwared (virtueel, HWID=$HWID)"
chroot "$ROOT" /usr/bin/env -i PATH=$PATHV RAUMFELD_VIRTUALISED_HARDWARE_ID=$HWID \
  G_FILENAME_ENCODING=UTF-8,ISO-8859-1 RAUMFELD_LOG_TARGET=buffers /bin/sh -lc '
    /etc/init.d/S30dbus start          >/dev/null 2>&1
    /etc/init.d/S50avahi-daemon start  >/dev/null 2>&1
    /etc/init.d/S85hardwared start     >/dev/null 2>&1
  '
for i in $(seq 1 20); do [ -S "$SOCK" ] && break; sleep 0.3; done
[ -S "$SOCK" ] && echo "  system-bus OK" || { echo "  !! geen system-bus"; exit 1; }

say "6) connman-stub starten op de chroot-bus"
pkill -x python3 2>/dev/null; sleep 1
setsid python3 "$STUB" "unix:path=$SOCK" </dev/null >/tmp/connman-stub.log 2>&1 &
for i in $(seq 1 20); do
  timeout 4 env DBUS_SYSTEM_BUS_ADDRESS="unix:path=$SOCK" dbus-send --system --dest=org.freedesktop.DBus \
    --print-reply /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner string:net.connman 2>/dev/null | grep -q true && break
  sleep 0.3
done
echo "  net.connman: $(timeout 4 env DBUS_SYSTEM_BUS_ADDRESS=unix:path=$SOCK dbus-send --system --dest=org.freedesktop.DBus --print-reply /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner string:net.connman 2>/dev/null | grep -o 'boolean.*')"

say "7) master-process starten (renderer + UPnP announce op $IFACE)"
: > "$MLOG"
setsid chroot "$ROOT" /usr/bin/env -i PATH=$PATHV RAUMFELD_VIRTUALISED_HARDWARE_ID=$HWID \
  G_FILENAME_ENCODING=UTF-8,ISO-8859-1 RAUMFELD_LOG_TARGET=stderr HOME=/root /bin/sh -lc '
    eval $(dbus-launch --sh-syntax)
    /raumfeld/hardwared/hw-cli set-indication initializing 2>/dev/null
    /usr/bin/raumfeld-key-creator 2>&1 | tail -1
    cd /raumfeld/master-process
    exec ./master-process
  ' </dev/null >>"$MLOG" 2>&1 &

echo "  master-process gestart; ~25s opstarten."

say "8) volume-brug starten (hardwared.Volume -> HiFiBerry Digital)"
pkill -f vc-volume-bridge 2>/dev/null; sleep 1
BRIDGE=$TOOLS/vc-volume-bridge.py; [ -f "$BRIDGE" ] || BRIDGE=/tmp/vc-volume-bridge.py
setsid python3 "$BRIDGE" "${ALSADEV#hw:}" </dev/null >/tmp/vc-volume-bridge.log 2>&1 &
echo "  volume-brug gestart ($BRIDGE, card ${ALSADEV#hw:})"

echo
echo "Klaar. In de Raumfeld-app verschijnt de kamer 'Raumfeld Connector' (renoembaar),"
echo "audio -> HiFiBerry (hw:1), volume via de app-knop."
