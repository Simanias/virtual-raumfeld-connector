#!/bin/bash
# Stopt de virtuele Connector en ruimt de chroot-mounts op. Draai als root op de Pi.
set -u
ROOT=${ROOT:-/opt/rfconnector}
[ "$(id -u)" = 0 ] || { echo "root nodig (sudo)"; exit 1; }

chroot "$ROOT" /bin/sh -lc '
  /etc/init.d/S99master-process stop 2>/dev/null
  /etc/init.d/S85hardwared      stop 2>/dev/null
  /etc/init.d/S50avahi-daemon   stop 2>/dev/null
  /etc/init.d/S30dbus           stop 2>/dev/null
' 2>/dev/null

for p in streamcastd renderer hardwared master-process avahi-daemon dbus-daemon; do
  pkill -f "$p" 2>/dev/null
done

umount "$ROOT/proc/device-tree/model" 2>/dev/null
umount -R "$ROOT/dev" 2>/dev/null
umount "$ROOT/run" "$ROOT/sys" "$ROOT/proc" 2>/dev/null
echo "gestopt + unmounted."
