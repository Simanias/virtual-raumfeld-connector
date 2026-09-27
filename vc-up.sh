#!/bin/bash
# Breng de VIRTUELE Raumfeld Connector op de Pi omhoog — chroot + ConnMan dbus-stub.
# Raakt wlan0 NIET aan (echte connmand is onschadelijk gemaakt; stub levert alleen dbus).
# Gebruik:  sudo bash /tmp/vc-up.sh
set -u
TOOLS=${TOOLS:-/opt/virtualtools}      # systeembrede locatie van deze tools
ROOT=${ROOT:-/opt/rfconnector}
HWID=9                                  # 9 = Raumfeld Connector 2
# --- audio-uitgang: gekozen bij installatie (vc.conf, op kaartNAAM), anders autodetect ---
[ -f "$TOOLS/vc.conf" ] && . "$TOOLS/vc.conf"          # VC_CARD=<kaartnaam>, optioneel VC_CTL=<mixer>
card_ids(){ aplay -l 2>/dev/null | awk '/^card [0-9]+:/{print $3}' | awk '!s[$0]++'; }
card_kind(){ case "$(aplay -l 2>/dev/null | grep -m1 "^card [0-9]*: $1 " | tr 'A-Z' 'a-z')" in
  *hdmi*|*vc4*) echo hdmi;; *bcm2835*|*headphone*) echo onboard;; *) echo extern;; esac; }
auto_card(){ local k c; for k in extern onboard hdmi; do for c in $(card_ids); do
  [ "$(card_kind "$c")" = "$k" ] && { echo "$c"; return; }; done; done; }
# override: ALSADEV=hw:N / hw:NAAM
if [ -n "${ALSADEV:-}" ]; then VC_CARD=${ALSADEV#hw:}; VC_CARD=${VC_CARD#CARD=}; fi
case "${VC_CARD:-}" in
  ''|auto) VC_CARD=$(auto_card) ;;
  *[!0-9]*) ;;                                           # al een naam
  *) VC_CARD=$(aplay -l 2>/dev/null | awk -v n="$VC_CARD" '$1=="card" && $2==n":"{print $3; exit}') ;;
esac
if ! card_ids | grep -qx "${VC_CARD:-none}"; then
  echo "  !! gekozen audio-kaart '${VC_CARD:-}' niet gevonden — autodetect"; VC_CARD=$(auto_card)
fi
ALSADEV="hw:$VC_CARD"
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
# EIGEN devtmpfs voor de chroot — NOOIT 'mount --rbind /dev', want dan kan een (lazy) unmount
# via mount-propagation de host-/dev meesleuren en valt de Pi van het netwerk.
mountpoint -q "$ROOT/dev"     || mount -t devtmpfs devtmpfs "$ROOT/dev"
mountpoint -q "$ROOT/dev/pts" || mount -t devpts   devpts   "$ROOT/dev/pts" 2>/dev/null || true
mountpoint -q "$ROOT/run"  || mount -t tmpfs tmpfs "$ROOT/run"

say "2) connmand onschadelijk (wlan0 blijft met rust)"
[ -e "$ROOT/usr/sbin/connmand" ] && mv "$ROOT/usr/sbin/connmand" "$ROOT/usr/sbin/connmand.real" && echo "  hernoemd" || echo "  al onschadelijk"

say "2b) renderer-wrapper (niet-virtueel -> opent echt ALSA-device i.p.v. netwerk-stream)"
if [ -f "$ROOT/raumfeld/renderer/renderer" ] && [ ! -f "$ROOT/raumfeld/renderer/renderer.bin" ]; then
  mv "$ROOT/raumfeld/renderer/renderer" "$ROOT/raumfeld/renderer/renderer.bin"
  printf '#!/bin/sh\nunset RAUMFELD_VIRTUALISED_HARDWARE_ID\nexec /raumfeld/renderer/renderer.bin "$@"\n' > "$ROOT/raumfeld/renderer/renderer"
  chmod +x "$ROOT/raumfeld/renderer/renderer"
  echo "  wrapper geplaatst"
else echo "  al aanwezig"; fi

say "3) ALSA default -> $ALSADEV ($(card_kind "$VC_CARD"))"
cp -f /etc/resolv.conf "$ROOT/etc/resolv.conf" 2>/dev/null || true
# volumeregelaar van deze kaart: bekende namen eerst, anders de eerste met pvolume
pick_ctl(){ local c
  for c in Digital PCM Master Speaker Headphone; do
    amixer -c "$1" sget "$c" 2>/dev/null | grep -q "Capabilities:.*pvolume" && { echo "$c"; return; }
  done
  amixer -c "$1" scontents 2>/dev/null | awk '/^Simple mixer control/{n=$0} /Capabilities:.*pvolume/{sub(/^Simple mixer control \047/,"",n); sub(/\047,[0-9]+$/,"",n); print n; exit}'
}
[ -n "${VC_CTL:-}" ] || VC_CTL=$(pick_ctl "$VC_CARD")
if [ -n "$VC_CTL" ]; then
  cat > "$ROOT/etc/asound.conf" <<EOF
pcm.!default { type plug; slave.pcm "hw:$VC_CARD" }
ctl.!default { type hw; card "$VC_CARD" }
EOF
else
  # geen hardware-volume (bv. HDMI): software-volume "VC Volume" ertussen
  VC_CTL="VC Volume"
  cat > "$ROOT/etc/asound.conf" <<EOF
pcm.vcvol { type softvol; slave.pcm "plughw:$VC_CARD"; control { name "VC Volume"; card "$VC_CARD" } }
pcm.!default { type plug; slave.pcm "vcvol" }
ctl.!default { type hw; card "$VC_CARD" }
EOF
fi
echo "  volumeregelaar: $VC_CTL"

say "4) oude Raumfeld-processen opruimen (voorkomt poort-8888-conflict)"
for n in master-process renderer stream-decoder streamcastd config-service meta-server gc4a; do pkill -9 -x "$n" 2>/dev/null; done
sleep 1

say "5) system-dbus + avahi + hardwared (virtueel, HWID=$HWID)"
# schoon starten: stale chroot-dbus/hardwared + socket weg (voorkomt stub 'Connection refused' na herstart)
pkill -9 -x hardwared 2>/dev/null; pkill -f start-hardwared 2>/dev/null; pkill -f "connman-stub.py" 2>/dev/null
chroot "$ROOT" /bin/sh -c '/etc/init.d/S30dbus stop; /etc/init.d/S50avahi-daemon stop' >/dev/null 2>&1 || true
rm -f "$ROOT/run/dbus/system_bus_socket" "$ROOT/run/dbus/pid" 2>/dev/null || true
sleep 1
chroot "$ROOT" /usr/bin/env -i PATH=$PATHV RAUMFELD_VIRTUALISED_HARDWARE_ID=$HWID \
  G_FILENAME_ENCODING=UTF-8,ISO-8859-1 RAUMFELD_LOG_TARGET=buffers /bin/sh -lc '
    /etc/init.d/S30dbus start          >/dev/null 2>&1
    /etc/init.d/S50avahi-daemon start  >/dev/null 2>&1
    /etc/init.d/S85hardwared start     >/dev/null 2>&1
  '
for i in $(seq 1 20); do [ -S "$SOCK" ] && break; sleep 0.3; done
[ -S "$SOCK" ] && echo "  system-bus OK" || { echo "  !! geen system-bus"; exit 1; }

say "6) connman-stub starten op de chroot-bus"
pkill -f "connman-stub.py" 2>/dev/null; sleep 1
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

say "8) volume-brug starten (hardwared.Volume -> $VC_CARD/$VC_CTL)"
pkill -f vc-volume-bridge 2>/dev/null; sleep 1
BRIDGE=$TOOLS/vc-volume-bridge.py; [ -f "$BRIDGE" ] || BRIDGE=/tmp/vc-volume-bridge.py
setsid python3 "$BRIDGE" "$VC_CARD" "$VC_CTL" </dev/null >/tmp/vc-volume-bridge.log 2>&1 &
echo "  volume-brug gestart ($BRIDGE, $VC_CARD / $VC_CTL)"

echo
echo "Klaar. De Virtuele Connector verschijnt in de Raumfeld-app (renoembaar),"
echo "audio -> $ALSADEV ($(card_kind "$VC_CARD")), volume via de app-knop ($VC_CTL)."
