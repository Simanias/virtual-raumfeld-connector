#!/bin/bash
# Stop de virtuele Raumfeld Connector netjes (laat wlan0 met rust).
# Gebruik:  sudo bash /tmp/vc-down.sh
ROOT=/opt/rfconnector
for n in master-process renderer stream-decoder streamcastd config-service meta-server gc4a; do pkill -9 -x "$n" 2>/dev/null; done
pkill -x python3 2>/dev/null                     # de connman-stub
chroot "$ROOT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/sh -lc '
  /etc/init.d/S85hardwared stop     >/dev/null 2>&1
  /etc/init.d/S50avahi-daemon stop  >/dev/null 2>&1
  /etc/init.d/S30dbus stop          >/dev/null 2>&1
' 2>/dev/null
# mounts los (best effort; volgorde omgekeerd)
for m in run dev/pts dev sys proc; do umount -l "$ROOT/$m" 2>/dev/null; done
echo "gestopt. wlan0:"; ip -4 addr show wlan0 | grep -o "inet 192[0-9.]*" || echo "  (check netwerk)"
