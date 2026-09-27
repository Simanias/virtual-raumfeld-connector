#!/bin/bash
# Self-healing: herstart de virtuele Connector-stack zodra het IP van de netwerk-interface
# verandert (DHCP-wijziging). De renderer/master-process binden hun UPnP/SSDP aan het IP dat
# bij het starten geldig was; verandert dat, dan bindt 'ie op een dood adres -> SSDP/subscribe-
# fouten en verdwijnt uit de app/HA/MA. Deze watcher herstart dan vc-connector, dat opnieuw op
# het actuele IP bindt. Bij een VAST IP verandert er niks en herstart 'ie dus nooit.
set -u
IFACE=${IFACE:-}
[ -n "$IFACE" ] || IFACE=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
IFACE=${IFACE:-wlan0}
last=""
while true; do
  ip=$(ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  if [ -n "$ip" ] && [ "$ip" != "$last" ]; then
    if [ -n "$last" ]; then
      logger -t vc-ip-watch "IP van $IFACE gewijzigd: $last -> $ip; herstart vc-connector"
      systemctl restart vc-connector
    fi
    last="$ip"
  fi
  sleep 15
done
