#!/bin/bash
# Stop de virtuele Raumfeld Connector netjes — laat wlan0 EN de host met rust.
ROOT=${ROOT:-/opt/rfconnector}
for n in master-process renderer renderer.bin stream-decoder streamcastd config-service meta-server gc4a; do
  pkill -9 -x "$n" 2>/dev/null
done
pkill -f "connman-stub.py"    2>/dev/null    # alleen de stub (NIET alle python3 op de host)
pkill -f "vc-volume-bridge.py" 2>/dev/null   # de volume-brug
chroot "$ROOT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/sh -lc '
  /etc/init.d/S85hardwared stop     >/dev/null 2>&1
  /etc/init.d/S50avahi-daemon stop  >/dev/null 2>&1
  /etc/init.d/S30dbus stop          >/dev/null 2>&1
' 2>/dev/null
# unmounts — EERST de /dev-rbind rslave maken, zodat lazy-unmount NOOIT de host-/dev raakt
# (anders kan de Pi van het netwerk vallen). Daarna in omgekeerde volgorde losmaken.
mount --make-rslave "$ROOT/dev" 2>/dev/null || true
for m in run dev/pts dev sys proc; do umount -l "$ROOT/$m" 2>/dev/null; done
echo "gestopt. wlan0:"; ip -4 addr show wlan0 2>/dev/null | grep -o "inet 192[0-9.]*" || echo "  (check netwerk)"
