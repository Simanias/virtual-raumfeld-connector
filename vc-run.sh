#!/bin/bash
# Virtuele Raumfeld Connector op de Pi — chroot + ConnMan dbus-stub (netwerk onaangeroerd).
# Draai als root op de Pi:  sudo /tmp/vc-run.sh
set -u
ROOT=/opt/rfconnector
HWID=9                      # 9 = Raumfeld Connector 2
ALSADEV=hw:1               # HiFiBerry DAC+ADC (card 1; card 0 = HDMI)
STUB=/tmp/connman-stub.py
SYSBUS="$ROOT/run/dbus/system_bus_socket"
MLOG=/tmp/vc-master.log
CENV="RAUMFELD_VIRTUALISED_HARDWARE_ID=$HWID G_FILENAME_ENCODING=UTF-8,ISO-8859-1"
PATHV=/usr/sbin:/usr/bin:/sbin:/bin

say(){ echo "== $* =="; }

say "1) pseudo-fs mounten"
for m in proc sys dev dev/pts run tmp; do mkdir -p "$ROOT/$m"; done
mountpoint -q "$ROOT/proc" || mount -t proc  proc  "$ROOT/proc"
mountpoint -q "$ROOT/sys"  || mount -t sysfs sys   "$ROOT/sys"
mountpoint -q "$ROOT/dev"  || mount --rbind /dev   "$ROOT/dev"
mountpoint -q "$ROOT/run"  || mount -t tmpfs tmpfs "$ROOT/run"

say "2) connmand onschadelijk maken (wlan0 blijft met rust)"
if [ -e "$ROOT/usr/sbin/connmand" ]; then
  mv "$ROOT/usr/sbin/connmand" "$ROOT/usr/sbin/connmand.real"
  echo "  connmand -> connmand.real"
else
  echo "  connmand al hernoemd"
fi

say "3) ALSA default -> $ALSADEV"
cp -f /etc/resolv.conf "$ROOT/etc/resolv.conf" 2>/dev/null || true
cat > "$ROOT/etc/asound.conf" <<EOF
pcm.!default { type plug; slave.pcm "$ALSADEV" }
ctl.!default { type hw; card ${ALSADEV#hw:} }
EOF

say "4) system-dbus + avahi + hardwared (virtueel, HWID=$HWID)"
chroot "$ROOT" /usr/bin/env -i PATH=$PATHV $CENV RAUMFELD_LOG_TARGET=buffers /bin/sh -lc '
  /etc/init.d/S30dbus start          2>&1 | tail -1
  /etc/init.d/S50avahi-daemon start  2>&1 | tail -1
  /etc/init.d/S85hardwared start     2>&1 | tail -1
'
# wacht op de system-bus socket
for i in $(seq 1 20); do [ -S "$SYSBUS" ] && break; sleep 0.3; done
[ -S "$SYSBUS" ] && echo "  system-bus socket OK" || echo "  !! geen system-bus socket"

say "5) connman-stub starten op de chroot-system-bus"
if ! DBUS_SYSTEM_BUS_ADDRESS="unix:path=$SYSBUS" dbus-send --system --dest=org.freedesktop.DBus \
      --print-reply /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner string:net.connman 2>/dev/null | grep -q true; then
  DBUS_SYSTEM_BUS_ADDRESS="unix:path=$SYSBUS" setsid python3 "$STUB" >/tmp/connman-stub.log 2>&1 &
  for i in $(seq 1 20); do
    DBUS_SYSTEM_BUS_ADDRESS="unix:path=$SYSBUS" dbus-send --system --dest=org.freedesktop.DBus \
      --print-reply /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner string:net.connman 2>/dev/null | grep -q true && break
    sleep 0.3
  done
fi
if DBUS_SYSTEM_BUS_ADDRESS="unix:path=$SYSBUS" dbus-send --system --dest=org.freedesktop.DBus \
     --print-reply /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner string:net.connman 2>/dev/null | grep -q true; then
  echo "  net.connman geclaimd door de stub"
else
  echo "  !! stub claimde net.connman NIET — zie /tmp/connman-stub.log"; tail -5 /tmp/connman-stub.log 2>/dev/null
fi

say "6) master-process starten (direct, stderr-log -> $MLOG)"
: > "$MLOG"
chroot "$ROOT" /usr/bin/env -i PATH=$PATHV $CENV RAUMFELD_LOG_TARGET=stderr /bin/sh -lc '
  eval $(dbus-launch --sh-syntax)
  /raumfeld/hardwared/hw-cli set-indication initializing 2>/dev/null
  /usr/bin/raumfeld-key-creator 2>&1 | tail -2
  cd /raumfeld/master-process
  exec ./master-process
' >>"$MLOG" 2>&1 &
echo "  master-process gestart (pid $!), 22s laten opstarten..."
sleep 22

say "7) status"
echo "-- processen in de chroot --"
chroot "$ROOT" ps w 2>/dev/null | grep -E "hardwared|master-process|renderer|streamcastd|gc4a|config-service|meta" | grep -v grep || echo "  (geen renderer/streamcastd)"
echo "-- laatste master-process log --"
tail -n 30 "$MLOG"
echo
echo "wlan0 check:"; ip -4 addr show wlan0 | grep inet || echo "  !! wlan0 weg"
