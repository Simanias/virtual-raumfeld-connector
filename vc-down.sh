#!/bin/bash
# Stop de virtuele Raumfeld Connector netjes — laat wlan0 EN de host met rust.
# Belangrijk: NIET de init.d-stopscripts van de firmware gebruiken. Die doen 'killall dbus-daemon' e.d.,
# en killall ziet vanuit de chroot (via /proc) ook de processen van de Pi zelf -> de dbus van de Pi
# gaat dood, NetworkManager/WiFi en avahi vallen weg. We killen alleen processen waarvan de root de chroot is.
ROOT=${ROOT:-/opt/rfconnector}
chroot_pids(){ local p; for p in /proc/[0-9]*; do [ "$(readlink "$p/root" 2>/dev/null)" = "$ROOT" ] && echo "${p#/proc/}"; done; }
chroot_kill(){ local pids; pids=$(chroot_pids); [ -n "$pids" ] && kill -"${1:-TERM}" $pids 2>/dev/null; return 0; }

pkill -f "connman-stub.py"     2>/dev/null   # stub (draait op de host)
pkill -f "vc-volume-bridge.py" 2>/dev/null   # volume-brug (draait op de host)
chroot_kill TERM; sleep 2; chroot_kill KILL
rm -f "$ROOT/run/dbus/system_bus_socket" "$ROOT/run/messagebus.pid" "$ROOT/var/run/messagebus.pid" "$ROOT/run/avahi-daemon/pid" 2>/dev/null

# chroot-mounts los (eigen devtmpfs/proc/sys/tmpfs — geen binds van de host)
for m in run dev/pts dev sys proc; do umount -l "$ROOT/$m" 2>/dev/null; done
echo "gestopt. wlan0:"; ip -4 addr show wlan0 2>/dev/null | grep -o "inet [0-9.]*" || echo "  (check netwerk)"
