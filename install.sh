#!/bin/bash
# Virtuele Raumfeld Connector — installer voor Raspberry Pi OS 32-bit (armhf) Lite.
#
#   wget -qO- https://raw.githubusercontent.com/Simanias/virtual-raumfeld-connector/main/install.sh | sudo bash
#
# Draait de Raumfeld Connector-firmware (userspace) in een chroot, met je eigen DAC als
# volwaardige Raumfeld-renderer. De firmware wordt bij de installatie rechtstreeks van
# Teufel's officiele update-server gehaald (we verspreiden zelf geen firmware).
set -euo pipefail

REPO_RAW="${VC_REPO_RAW:-https://raw.githubusercontent.com/Simanias/virtual-raumfeld-connector/main}"
TOOLS=/opt/virtualtools
ROOT=/opt/rfconnector
HWID=9                                   # 9 = Raumfeld Connector 2
UPDATES_HOST="updates.raumfeld.com"
SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo /dev/null)"
FILES="connman-stub.py vc-up.sh vc-down.sh vc-master.sh vc-volume-bridge.py vc-ip-watch.sh vc-setup.sh raumfeld-setup.json"
SERVICES="vc-connector.service vc-ip-watch.service"

c(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ask(){ local p="$1" d="${2:-}" a=""; if [ -r /dev/tty ]; then read -r -p "$p" a </dev/tty || true; fi; echo "${a:-$d}"; }
fetch(){ # fetch <naam> <doel> : lokaal kopieren indien aanwezig, anders van de repo halen
  if [ -f "$SRCDIR/$1" ]; then cp -f "$SRCDIR/$1" "$2"; else curl -fsSL "$REPO_RAW/$1" -o "$2"; fi; }

[ "$(id -u)" = 0 ] || { echo "Draai als root:  sudo bash install.sh"; exit 1; }

c "0) Checks"
arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "$arch" in armhf|armv7l) echo "  arch $arch OK";; *) echo "  LET OP: verwacht 32-bit armhf (Pi OS Lite), gevonden '$arch' — rootfs draait mogelijk niet.";; esac

c "1) Pakketten"
apt-get update -qq
apt-get install -y -qq python3-dbus python3-gi xz-utils curl coreutils util-linux alsa-utils >/dev/null
echo "  ok"

c "2) Firmware (Connector 2 / HWID $HWID) van Teufel halen + rootfs uitpakken"
if [ -d "$ROOT/raumfeld" ]; then
  echo "  rootfs bestaat al in $ROOT — overslaan."
else
  mkdir -p "$ROOT"
  hash=$(curl -fsSL "https://$UPDATES_HOST/$HWID.updates" | tr -d '[] \t\r' | head -1)
  [ -n "$hash" ] || { echo "  kon firmware-index niet lezen"; exit 1; }
  echo "  blob $hash — downloaden (~27MB) + uitpakken ..."
  curl -fsSL "https://$UPDATES_HOST/$hash" | xz -d | tar -x -C "$ROOT"
  echo "  rootfs in $ROOT"
fi

c "3) Tooling -> $TOOLS"
mkdir -p "$TOOLS"
for f in $FILES; do fetch "$f" "$TOOLS/$f"; done
chmod +x "$TOOLS"/*.sh
for s in $SERVICES; do fetch "$s" "/etc/systemd/system/$s"; done

c "4) Keuzes"
echo "Audio-devices op deze Pi:"; aplay -l 2>/dev/null | grep '^card' || echo "  (geen — sluit je DAC aan / schakel de overlay in)"
autocard=$(aplay -l 2>/dev/null | awk '/^card [0-9]+:/{n=$2; sub(/:.*/,"",n); if (tolower($0)!~/hdmi|vc4/){print n; exit}}')
CARD=$(ask "Audio-kaartnummer [${autocard:-1}]: " "${autocard:-1}")
DEVNAME=$(ask "Device-naam [Virtual Connector]: " "Virtual Connector")
ROOM=$(ask "Kamernaam in Raumfeld [$DEVNAME]: " "$DEVNAME")
echo "system-id = de systeem-UUID van je Raumfeld-systeem (op een bestaand toestel: /var/raumfeld-1.0/system-id)"
SYSID=$(ask "Raumfeld system-id (leeg = later registreren): " "")

c "5) Device-naam + firmware-update onderdrukken"
mkdir -p "$ROOT/var/raumfeld-1.0"
printf '[GLOBAL]\nrenderer-name=%s\n' "$DEVNAME" > "$ROOT/var/raumfeld-1.0/renderer-config.ini"
echo "  device-naam: $DEVNAME"
touch "$ROOT/etc/hosts"
grep -q "$UPDATES_HOST" "$ROOT/etc/hosts" || printf '127.0.0.1 %s raumfeld.updates.teufel.de\n' "$UPDATES_HOST" >> "$ROOT/etc/hosts"
echo "  firmware-updates geblokkeerd in de chroot (voorkomt kapotte update)"

c "6) Services activeren (auto-start bij boot + IP-watcher)"
systemctl daemon-reload
systemctl enable vc-connector vc-ip-watch >/dev/null 2>&1 || true
echo "  vc-connector + vc-ip-watch enabled"

c "7) Stack starten (audio -> card $CARD)"
ALSADEV="hw:$CARD" bash "$TOOLS/vc-up.sh" || true
systemctl start vc-ip-watch 2>/dev/null || true
sleep 18

c "8) Registreren als kamer in je Raumfeld-systeem"
if [ -n "$SYSID" ]; then
  ALSADEV="hw:$CARD" bash "$TOOLS/vc-setup.sh" "$ROOM" "$SYSID" || echo "  (registratie niet bevestigd — check /tmp/vc-master.log)"
else
  echo "  Geen system-id opgegeven. Registreer later met:"
  echo "     sudo bash $TOOLS/vc-setup.sh \"$ROOM\" <system-id>"
fi

c "KLAAR"
IP=$(ip -4 -o addr show "$(ip route|awk '/^default/{print $5;exit}')" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
echo "Virtuele Connector '$DEVNAME' draait (IP ${IP:-?}), audio -> card $CARD, en start automatisch na een reboot."
echo "TIP: geef de Pi een vast IP (DHCP-reservering) om her-ontdek-hikjes te voorkomen."
