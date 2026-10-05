#!/bin/bash
# Bring up the VIRTUAL Raumfeld Connector on the Pi — chroot + ConnMan D-Bus stub.
# Does NOT touch wlan0 (the real connmand is neutralised; the stub only provides D-Bus).
# Usage:  sudo bash /opt/virtualtools/vc-up.sh   (normally started by vc-connector.service)
set -u
TOOLS=${TOOLS:-/opt/virtualtools}      # system-wide location of these tools
ROOT=${ROOT:-/opt/rfconnector}
HWID=9                                  # 9 = Raumfeld Connector 2
# --- audio output: chosen during installation (vc.conf, by card NAME), otherwise autodetect ---
[ -f "$TOOLS/vc.conf" ] && . "$TOOLS/vc.conf"          # VC_CARD=<card name>, optional VC_CTL=<mixer>
card_ids(){ aplay -l 2>/dev/null | awk '/^card [0-9]+:/ && !/\[Loopback\]/{print $3}' | awk '!s[$0]++'; }   # never the ALSA loopback
card_kind(){ case "$(aplay -l 2>/dev/null | grep -m1 "^card [0-9]*: $1 " | tr 'A-Z' 'a-z')" in
  *hdmi*|*vc4*) echo hdmi;; *bcm2835*|*headphone*) echo onboard;; *) echo external;; esac; }
auto_card(){ local k c; for k in external onboard hdmi; do for c in $(card_ids); do
  [ "$(card_kind "$c")" = "$k" ] && { echo "$c"; return; }; done; done; }
# override: ALSADEV=hw:N / hw:NAME
if [ -n "${ALSADEV:-}" ]; then VC_CARD=${ALSADEV#hw:}; VC_CARD=${VC_CARD#CARD=}; fi
case "${VC_CARD:-}" in
  ''|auto) VC_CARD=$(auto_card) ;;
  *[!0-9]*) ;;                                           # already a name
  *) VC_CARD=$(aplay -l 2>/dev/null | awk -v n="$VC_CARD" '$1=="card" && $2==n":"{print $3; exit}') ;;
esac
if ! card_ids | grep -qx "${VC_CARD:-none}"; then
  echo "  !! chosen sound card '${VC_CARD:-}' not found — autodetecting"; VC_CARD=$(auto_card)
fi
ALSADEV="hw:$VC_CARD"
SOCK="$ROOT/run/dbus/system_bus_socket"
STUB=$TOOLS/connman-stub.py; [ -f "$STUB" ] || STUB=/tmp/connman-stub.py
MLOG=/tmp/vc-master.log
PATHV=/usr/sbin:/usr/bin:/sbin:/bin
say(){ echo "== $* =="; }
# processes whose root is the chroot — safe to kill without ever hitting a host process
chroot_pids(){ local p; for p in /proc/[0-9]*; do [ "$(readlink "$p/root" 2>/dev/null)" = "$ROOT" ] && echo "${p#/proc/}"; done; }
chroot_kill(){ local pids; pids=$(chroot_pids); [ -n "$pids" ] && kill -"${1:-TERM}" $pids 2>/dev/null; return 0; }

[ "$(id -u)" = 0 ] || { echo "Run as root (sudo)."; exit 1; }

# --- detect network details (for the stub) ---
IFACE=$(ip route | awk '/^default/{print $5; exit}')
IPCIDR=$(ip -4 -o addr show "$IFACE" | awk '{print $4; exit}')
export VC_IFACE="$IFACE"
export VC_IP="${IPCIDR%/*}"
export VC_MAC="$(cat /sys/class/net/$IFACE/address)"
export VC_GW="$(ip route | awk '/^default/{print $3; exit}')"
export VC_NETMASK="$(python3 -c 'import ipaddress,sys;print(ipaddress.IPv4Network("0.0.0.0/"+sys.argv[1]).netmask)' "${IPCIDR#*/}")"
echo "  net: $VC_IFACE $VC_IP/$VC_NETMASK gw $VC_GW mac $VC_MAC"

say "1) mount pseudo filesystems"
for m in proc sys dev dev/pts run tmp; do mkdir -p "$ROOT/$m"; done
mountpoint -q "$ROOT/proc" || mount -t proc  proc  "$ROOT/proc"
mountpoint -q "$ROOT/sys"  || mount -t sysfs sys   "$ROOT/sys"
# a SEPARATE devtmpfs for the chroot — never 'mount --rbind /dev', a (lazy) unmount could otherwise
# drag the host's /dev along via mount propagation.
mountpoint -q "$ROOT/dev"     || mount -t devtmpfs devtmpfs "$ROOT/dev"
mountpoint -q "$ROOT/dev/pts" || mount -t devpts   devpts   "$ROOT/dev/pts" 2>/dev/null || true
mountpoint -q "$ROOT/run"  || mount -t tmpfs tmpfs "$ROOT/run"

say "2) neutralise connmand (wlan0 is left alone)"
[ -e "$ROOT/usr/sbin/connmand" ] && mv "$ROOT/usr/sbin/connmand" "$ROOT/usr/sbin/connmand.real" && echo "  renamed" || echo "  already neutralised"

say "2b) renderer wrapper (plays to a real ALSA device instead of the network stream)"
R="$ROOT/raumfeld/renderer"
[ -f "$R/renderer.bin" ] || mv "$R/renderer" "$R/renderer.bin"
# Connector 2 mode: the renderer identifies as a real Connector 2 (hardware id 9), so the EQ and LED
# settings from the app reach this device. With an input on the card the renderer also opens it as its
# line-in; without one it is told there is no line-in (--no-input) and gets a DSP chain without it.
# VC_MODE=basic keeps the renderer non-virtualised instead (no EQ/LED).
MODE=basic; CAP=""
if [ "${VC_MODE:-auto}" != basic ]; then
  arecord -l 2>/dev/null | grep -q "^card [0-9]*: $VC_CARD " && CAP="hw:$VC_CARD"
  python3 "$TOOLS/vc-renderer-libs.py" "$ROOT" "$R/vc-lib" $([ -n "$CAP" ] || echo --no-input) && MODE=connector2
fi
if [ "$MODE" = connector2 ]; then
  printf '#!/bin/sh\n# Connector 2 (hardware id 9) that plays to ALSA — see vc-renderer-libs.py\nLD_LIBRARY_PATH=/raumfeld/renderer/vc-lib exec /raumfeld/renderer/renderer.bin "$@"\n' > "$R/renderer"
  # the renderer's DSP chain: the firmware's own (with line-in) plus the EQ module, or a plain one without line-in
  X="$R/dsp-config/raumfeld-connector-2.xml"
  [ -f "$X.orig" ] || cp -a "$X" "$X.orig"
  python3 - "$X" "${CAP:+input}" <<'PY'
import re, sys
p = sys.argv[1]
EQ = ('<stereo-module id="user-eq" type="equalizer">\n      <parameter id="gain-correction">yes</parameter>\n'
      '    </stereo-module>\n')
if sys.argv[2:] == ["input"]:
    t = open(p + ".orig").read()
    t = t.replace('<module id="output" type="output">', EQ + '    <module id="output" type="output">', 1)
    t = re.sub(r'<cable out="([^"]+)" in="output"/>',
               r'<cable out="\1" in="user-eq"/>\n    <cable out="user-eq" in="output"/>', t, count=1)
else:
    t = ('<dsp>\n  <modules>\n    <module id="stream-decoder" type="input"/>\n'
         '    <stereo-module id="timestretcher" type="timestretcher"/>\n    ' + EQ +
         '    <module id="output" type="output">\n      <parameter id="interleave-pattern">01</parameter>\n'
         '    </module>\n  </modules>\n  <cabling>\n    <cable out="stream-decoder" in="timestretcher"/>\n'
         '    <cable out="timestretcher" in="user-eq"/>\n    <cable out="user-eq" in="output"/>\n'
         '  </cabling>\n</dsp>\n')
try: same = open(p).read() == t
except OSError: same = False
if not same: open(p, "w").write(t)
PY
  echo "  Connector 2 mode (EQ + LED from the app), line-in: ${CAP:-none}"
else
  printf '#!/bin/sh\nunset RAUMFELD_VIRTUALISED_HARDWARE_ID\nexec /raumfeld/renderer/renderer.bin "$@"\n' > "$R/renderer"
  echo "  basic mode (no EQ/LED: VC_MODE=basic, or the renderer libraries could not be prepared)"
fi
chmod +x "$R/renderer"

say "3) ALSA default -> $ALSADEV ($(card_kind "$VC_CARD"))"
# DNS: in the firmware /etc/resolv.conf is a symlink to ../tmp/resolv.conf (normally filled by connman);
# 'cp' refuses to write through such a dangling symlink, so fill the target directly.
mkdir -p "$ROOT/tmp"; cat /etc/resolv.conf > "$ROOT/tmp/resolv.conf" 2>/dev/null || true
[ -L "$ROOT/etc/resolv.conf" ] || cat /etc/resolv.conf > "$ROOT/etc/resolv.conf" 2>/dev/null || true
# volume control of this card: well-known names first, otherwise the first one with pvolume
pick_ctl(){ local c
  for c in Digital PCM Master Speaker Headphone; do
    amixer -c "$1" sget "$c" 2>/dev/null | grep -q "Capabilities:.*pvolume" && { echo "$c"; return; }
  done
  amixer -c "$1" scontents 2>/dev/null | awk '/^Simple mixer control/{n=$0} /Capabilities:.*pvolume/{sub(/^Simple mixer control \047/,"",n); sub(/\047,[0-9]+$/,"",n); print n; exit}'
}
[ -n "${VC_CTL:-}" ] || VC_CTL=$(pick_ctl "$VC_CARD")
if [ -n "$VC_CTL" ]; then
  OUT="hw:$VC_CARD"
  cat > "$ROOT/etc/asound.conf" <<EOF
pcm.!default { type plug; slave.pcm "hw:$VC_CARD" }
ctl.!default { type hw; card "$VC_CARD" }
EOF
else
  # no hardware volume (e.g. HDMI): insert a software volume "VC Volume"
  VC_CTL="VC Volume"; OUT="vcvol"
  cat > "$ROOT/etc/asound.conf" <<EOF
pcm.vcvol { type softvol; slave.pcm "plughw:$VC_CARD"; control { name "VC Volume"; card "$VC_CARD" } }
pcm.!default { type plug; slave.pcm "vcvol" }
ctl.!default { type hw; card "$VC_CARD" }
EOF
fi
if [ "$MODE" = connector2 ]; then
  # a Connector 2 renderer plays to "raumfeld:<in bits>,<out bits>,<channels>,<card>,<device>,<delay>": the
  # firmware's own DSP plugin (it runs the renderer's DSP chain, with the EQ, right in front of the sound
  # card). Same definition as on a real device, but with our output as its slave instead of hw:<card>.
  cat >> "$ROOT/etc/asound.conf" <<EOF
pcm.raumfeld {
  @args [ INBITS OUTBITS OUTCHANNELS CARD DEVICE DELAY ]
  @args.INBITS.type = integer
  @args.OUTBITS.type = integer
  @args.OUTCHANNELS.type = integer
  @args.CARD.type = integer
  @args.DEVICE.type = integer
  @args.DELAY.type = integer
  type raumfeld
  in-bits \$INBITS
  out-bits \$OUTBITS
  out-channels \$OUTCHANNELS
  slave.pcm { type plug; slave.pcm "$OUT" }
}
EOF
  # the line-in (renamed from hw:0,0 to vc_cap in vc-renderer-libs.py) is the chosen card's own input
  [ -n "$CAP" ] && echo "pcm.vc_cap { type plug; slave.pcm \"$CAP\" }" >> "$ROOT/etc/asound.conf"
fi
echo "  volume control: $VC_CTL"

say "4) clean up old chroot processes (only processes INSIDE the chroot — the host is never touched)"
# NOTE: never use the firmware's init.d stop scripts: they do things like 'killall dbus-daemon', and
# from inside the chroot killall also sees the Pi's own dbus via /proc -> NetworkManager/WiFi drops out.
pkill -f "^python3 [^ ]*connman-stub.py" 2>/dev/null; pkill -f "^python3 [^ ]*vc-volume-bridge.py" 2>/dev/null
chroot_kill TERM; sleep 2; chroot_kill KILL
rm -f "$ROOT/run/dbus/system_bus_socket" "$ROOT/run/messagebus.pid" "$ROOT/var/run/messagebus.pid" "$ROOT/run/avahi-daemon/pid" 2>/dev/null || true

say "5) system dbus + avahi + hardwared (virtualised, HWID=$HWID)"
chroot "$ROOT" /usr/bin/env -i PATH=$PATHV RAUMFELD_VIRTUALISED_HARDWARE_ID=$HWID \
  G_FILENAME_ENCODING=UTF-8,ISO-8859-1 RAUMFELD_LOG_TARGET=buffers /bin/sh -lc '
    /etc/init.d/S30dbus start          >/dev/null 2>&1
    /etc/init.d/S50avahi-daemon start  >/dev/null 2>&1
    /etc/init.d/S85hardwared start     >/dev/null 2>&1
  '
for i in $(seq 1 20); do [ -S "$SOCK" ] && break; sleep 0.3; done
[ -S "$SOCK" ] && echo "  system bus OK" || { echo "  !! no system bus"; exit 1; }

say "6) start the connman stub on the chroot bus"
pkill -f "^python3 [^ ]*connman-stub.py" 2>/dev/null; sleep 1
setsid python3 "$STUB" "unix:path=$SOCK" </dev/null >/tmp/connman-stub.log 2>&1 &
for i in $(seq 1 20); do
  timeout 4 env DBUS_SYSTEM_BUS_ADDRESS="unix:path=$SOCK" dbus-send --system --dest=org.freedesktop.DBus \
    --print-reply /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner string:net.connman 2>/dev/null | grep -q true && break
  sleep 0.3
done
echo "  net.connman: $(timeout 4 env DBUS_SYSTEM_BUS_ADDRESS=unix:path=$SOCK dbus-send --system --dest=org.freedesktop.DBus --print-reply /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner string:net.connman 2>/dev/null | grep -o 'boolean.*')"

say "7) start master-process (renderer + UPnP announce on $IFACE)"
: > "$MLOG"
setsid chroot "$ROOT" /usr/bin/env -i PATH=$PATHV RAUMFELD_VIRTUALISED_HARDWARE_ID=$HWID \
  G_FILENAME_ENCODING=UTF-8,ISO-8859-1 RAUMFELD_LOG_TARGET=stderr HOME=/root /bin/sh -lc '
    eval $(dbus-launch --sh-syntax)
    /raumfeld/hardwared/hw-cli set-indication initializing 2>/dev/null
    /usr/bin/raumfeld-key-creator 2>&1 | tail -1
    cd /raumfeld/master-process
    exec ./master-process
  ' </dev/null >>"$MLOG" 2>&1 &

echo "  master-process started; takes ~25s to come up."

say "8) start the volume bridge (hardwared.Volume -> $VC_CARD/$VC_CTL)"
pkill -f "^python3 [^ ]*vc-volume-bridge.py" 2>/dev/null; sleep 1
BRIDGE=$TOOLS/vc-volume-bridge.py; [ -f "$BRIDGE" ] || BRIDGE=/tmp/vc-volume-bridge.py
VC_LEDS="${VC_LEDS:-1}" VC_SPANDB="${VC_SPANDB:-}" VC_MAXDB="${VC_MAXDB:-}" setsid python3 "$BRIDGE" "$VC_CARD" "$VC_CTL" </dev/null >/tmp/vc-volume-bridge.log 2>&1 &
echo "  volume bridge started ($BRIDGE, $VC_CARD / $VC_CTL)"

echo
echo "Done. The Virtual Connector shows up in the Raumfeld app (renameable),"
echo "audio -> $ALSADEV ($(card_kind "$VC_CARD")), volume via the app ($VC_CTL), $MODE mode."
