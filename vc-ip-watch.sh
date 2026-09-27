#!/bin/bash
# Self-healing: restart the Virtual Connector stack as soon as the IP of the network interface
# changes (DHCP change). The renderer/master-process bind their UPnP/SSDP to the IP that was valid
# at start-up; if it changes they are bound to a dead address -> SSDP/subscribe errors and the
# device disappears from the app/HA/MA. This watcher then restarts vc-connector, which binds to the
# current IP again. With a FIXED IP nothing changes, so it never restarts anything.
set -u
IFACE=${IFACE:-}
[ -n "$IFACE" ] || IFACE=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
IFACE=${IFACE:-wlan0}
last=""
while true; do
  ip=$(ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  if [ -n "$ip" ] && [ "$ip" != "$last" ]; then
    if [ -n "$last" ]; then
      logger -t vc-ip-watch "IP of $IFACE changed: $last -> $ip; restarting vc-connector"
      systemctl restart vc-connector
    fi
    last="$ip"
  fi
  sleep 15
done
