#!/bin/bash
# Cleanly stop the Virtual Raumfeld Connector — leaves wlan0 AND the host alone.
# Important: do NOT use the firmware's init.d stop scripts. They do 'killall dbus-daemon' and similar,
# and from inside the chroot killall also sees the Pi's own processes (via /proc) -> the Pi's dbus dies
# and NetworkManager/WiFi and avahi drop out. We only kill processes whose root is the chroot.
ROOT=${ROOT:-/opt/rfconnector}
chroot_pids(){ local p; for p in /proc/[0-9]*; do [ "$(readlink "$p/root" 2>/dev/null)" = "$ROOT" ] && echo "${p#/proc/}"; done; }
chroot_kill(){ local pids; pids=$(chroot_pids); [ -n "$pids" ] && kill -"${1:-TERM}" $pids 2>/dev/null; return 0; }

pkill -f "connman-stub.py"     2>/dev/null   # stub (runs on the host)
pkill -f "vc-volume-bridge.py" 2>/dev/null   # volume bridge (runs on the host)
chroot_kill TERM; sleep 2; chroot_kill KILL
rm -f "$ROOT/run/dbus/system_bus_socket" "$ROOT/run/messagebus.pid" "$ROOT/var/run/messagebus.pid" "$ROOT/run/avahi-daemon/pid" 2>/dev/null

# unmount the chroot mounts (own devtmpfs/proc/sys/tmpfs — no binds of the host)
for m in run dev/pts dev sys proc; do umount -l "$ROOT/$m" 2>/dev/null; done
echo "stopped. wlan0:"; ip -4 addr show wlan0 2>/dev/null | grep -o "inet [0-9.]*" || echo "  (check the network)"
