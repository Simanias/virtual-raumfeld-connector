#!/bin/bash
# Virtuele Raumfeld Connector — installer voor Raspberry Pi OS 32-bit (armhf) Lite.
#
#   wget -qO- https://raw.githubusercontent.com/Simanias/virtual-raumfeld-connector/main/install.sh | sudo bash
#
# Draait de Raumfeld Connector-firmware (userspace) in een chroot, met je eigen DAC als
# volwaardige Raumfeld-renderer. Firmware wordt bij installatie officieel bij Teufel opgehaald.
# Kan een DAC-overlay aanzetten en dan automatisch dóórgaan na een reboot (--resume).
set -uo pipefail

REPO_RAW="${VC_REPO_RAW:-https://raw.githubusercontent.com/Simanias/virtual-raumfeld-connector/main}"
TOOLS=/opt/virtualtools
ROOT=/opt/rfconnector
HWID=9
UPDATES_HOST="updates.raumfeld.com"
CONF="$TOOLS/install.conf"
RESUME_SVC=vc-install-resume
SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo /dev/null)"
FILES="connman-stub.py vc-up.sh vc-down.sh vc-master.sh vc-volume-bridge.py vc-ip-watch.sh vc-setup.sh"
SERVICES="vc-connector.service vc-ip-watch.service"
RESUME=0; [ "${1:-}" = "--resume" ] && RESUME=1
[ -n "${VC_DEBUG:-}" ] && set -x    # uitgebreide trace voor debugging

c(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
# ask <prompt> <default> [ENV_KEY] : env-var (indien gezet) wint -> non-interactieve/headless installs
ask(){ local p="$1" d="${2:-}" k="${3:-}" a=""; if [ -n "$k" ]; then eval "a=\${$k:-}"; [ -n "$a" ] && { echo "$a"; return; }; fi; if [ -r /dev/tty ]; then read -r -p "$p" a </dev/tty || true; fi; echo "${a:-$d}"; }
fetch(){ if [ -f "$SRCDIR/$1" ]; then cp -f "$SRCDIR/$1" "$2"; else curl -fsSL "$REPO_RAW/$1" -o "$2"; fi; }
bootcfg(){ [ -f /boot/firmware/config.txt ] && echo /boot/firmware/config.txt || echo /boot/config.txt; }
dac_card(){ aplay -l 2>/dev/null | awk '/^card [0-9]+:/{n=$2; sub(/:.*/,"",n); if (tolower($0)!~/hdmi|vc4|bcm2835|headphone/){print n; exit}}'; }

[ "$(id -u)" = 0 ] || { echo "Draai als root:  sudo bash install.sh"; exit 1; }
mkdir -p "$TOOLS"

# ---------- Fase 1: keuzes + eventueel DAC-overlay + reboot ----------
if [ "$RESUME" = 0 ]; then
  c "0) Checks + basispakketten"
  arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
  case "$arch" in armhf|armv7l) echo "  arch $arch OK";; *) echo "  LET OP: verwacht 32-bit armhf; '$arch' gevonden — rootfs draait mogelijk niet.";; esac
  apt-get update -qq && apt-get install -y -qq alsa-utils curl xz-utils python3-dbus python3-gi coreutils util-linux >/dev/null
  echo "  ok"

  c "1) Audio-device kiezen"
  echo "Kaarten nu aanwezig:"; aplay -l 2>/dev/null | grep '^card' || echo "  (geen DAC — kies hieronder een overlay)"
  CARD=""; OVERLAY=""
  if [ -n "${VC_CARD:-}" ]; then CARD="$VC_CARD"; echo "  (env) card $CARD"
  elif [ -n "${VC_OVERLAY:-}" ]; then OVERLAY="$VC_OVERLAY"; echo "  (env) overlay $OVERLAY"
  elif CARD=$(dac_card); [ -n "$CARD" ]; then
    echo "  DAC gevonden op card $CARD."
    keep=$(ask "Deze gebruiken? [J/n] of typ een overlay-naam: " "J")
    case "$keep" in J|j|"") ;; N|n) CARD=""; OVERLAY=$(ask "Overlay-naam (bijv. hifiberry-dacplusadc): " "");; *) OVERLAY="$keep"; CARD="";; esac
  else
    echo "Kies je DAC (zet de overlay aan; reboot volgt automatisch):"
    echo "  1) HiFiBerry DAC+ ADC        (hifiberry-dacplusadc)"
    echo "  2) HiFiBerry DAC+/DAC+ Pro   (hifiberry-dacplus)"
    echo "  3) HiFiBerry DAC (PCM5102A)  (hifiberry-dac)"
    echo "  4) HiFiBerry Digi/Digi+      (hifiberry-digi)"
    echo "  5) IQaudio DAC+              (iqaudio-dacplus)"
    echo "  6) USB-DAC / al aangesloten  (geen overlay)"
    echo "  7) Anders (typ zelf de overlay-naam)"
    sel=$(ask "Keuze [1]: " "1")
    case "$sel" in
      1) OVERLAY=hifiberry-dacplusadc;; 2) OVERLAY=hifiberry-dacplus;; 3) OVERLAY=hifiberry-dac;;
      4) OVERLAY=hifiberry-digi;; 5) OVERLAY=iqaudio-dacplus;; 6) OVERLAY="";; 7) OVERLAY=$(ask "Overlay-naam: " "");;
      *) OVERLAY=hifiberry-dacplusadc;;
    esac
  fi

  c "2) Overige keuzes"
  DEVNAME=$(ask "Device-naam [Virtual Connector]: " "Virtual Connector" VC_DEVNAME)
  ROOM=$(ask "Kamernaam in Raumfeld [$DEVNAME]: " "$DEVNAME" VC_ROOM)
  echo "system-id = de systeem-UUID van je Raumfeld-systeem (op een toestel: /var/raumfeld-1.0/system-id)."
  SYSID=$(ask "Raumfeld system-id (leeg = later/automatisch): " "" VC_SYSID)

  # keuzes bewaren voor (resume na) reboot
  { echo "DEVNAME=$(printf %q "$DEVNAME")"; echo "ROOM=$(printf %q "$ROOM")"; echo "SYSID=$(printf %q "$SYSID")"
    echo "CARD=$(printf %q "$CARD")"; echo "OVERLAY=$(printf %q "$OVERLAY")"; } > "$CONF"

  if [ -n "$OVERLAY" ]; then
    c "3) DAC-overlay aanzetten ($OVERLAY) + reboot"
    BC=$(bootcfg)
    grep -q "^dtoverlay=$OVERLAY" "$BC" || echo "dtoverlay=$OVERLAY" >> "$BC"
    sed -i 's/^dtparam=audio=on/dtparam=audio=off/' "$BC" 2>/dev/null || true
    echo "  overlay in $BC gezet; onboard audio uit."
    # resume-service die na de reboot de installatie afmaakt
    cat > /etc/systemd/system/$RESUME_SVC.service <<EOF
[Unit]
Description=Virtual Connector installer resume
After=network-online.target
Wants=network-online.target
ConditionPathExists=$CONF
[Service]
Type=oneshot
ExecStartPre=/bin/sleep 15
ExecStart=/bin/bash -c 'curl -fsSL $REPO_RAW/install.sh | bash -s -- --resume'
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable $RESUME_SVC >/dev/null 2>&1
    echo "  installatie gaat automatisch verder na de reboot. Rebooten in 5s..."; sleep 5; reboot; exit 0
  fi
fi

# ---------- Fase 2: installeren (inline of via resume na reboot) ----------
[ -f "$CONF" ] && . "$CONF"
: "${DEVNAME:=Virtual Connector}"; : "${ROOM:=$DEVNAME}"; : "${SYSID:=}"; : "${CARD:=}"; : "${OVERLAY:=}"
[ -n "$CARD" ] || CARD=$(dac_card); : "${CARD:=1}"

c "4) Pakketten + firmware (Connector 2 / HWID $HWID) van Teufel"
apt-get install -y -qq python3-dbus python3-gi xz-utils curl alsa-utils >/dev/null 2>&1 || true
if [ -d "$ROOT/raumfeld" ]; then echo "  rootfs bestaat al — overslaan."; else
  mkdir -p "$ROOT"
  hash=$(curl -fsSL "https://$UPDATES_HOST/$HWID.updates" | tr -d '[] \t\r' | head -1)
  [ -n "$hash" ] || { echo "  kon firmware-index niet lezen"; exit 1; }
  echo "  blob $hash — downloaden + uitpakken ..."
  curl -fsSL "https://$UPDATES_HOST/$hash" | xz -d | tar -x -C "$ROOT"
fi

c "5) Tooling + services"
for f in $FILES; do fetch "$f" "$TOOLS/$f"; done
chmod +x "$TOOLS"/*.sh
for s in $SERVICES; do fetch "$s" "/etc/systemd/system/$s"; done

c "6) Device-naam + model-label + update-blokkade (audio -> card $CARD)"
mkdir -p "$ROOT/var/raumfeld-1.0"
printf '[GLOBAL]\nrenderer-name=%s\n' "$DEVNAME" > "$ROOT/var/raumfeld-1.0/renderer-config.ini"
LIB="$ROOT/usr/lib/libraumfeld-1.0.so"
if [ -f "$LIB" ] && ! strings "$LIB" 2>/dev/null | grep -q '^Virtual Connector$'; then
  [ -f "$LIB.orig" ] || cp -a "$LIB" "$LIB.orig"
  python3 - "$LIB" <<'PY' || true
import sys
lib=sys.argv[1]; d=open(lib,"rb").read()
o=b"Raumfeld Connector\x00"; n=b"Virtual Connector\x00\x00"
if len(o)==len(n) and o in d: open(lib+".new","wb").write(d.replace(o,n))
PY
  [ -f "$LIB.new" ] && chmod --reference="$LIB" "$LIB.new" && mv "$LIB.new" "$LIB" && echo "  model-label -> Virtual Connector"
fi
touch "$ROOT/etc/hosts"; grep -q "$UPDATES_HOST" "$ROOT/etc/hosts" || printf '127.0.0.1 %s raumfeld.updates.teufel.de\n' "$UPDATES_HOST" >> "$ROOT/etc/hosts"

c "7) Services activeren"
systemctl daemon-reload; systemctl enable vc-connector vc-ip-watch >/dev/null 2>&1 || true

c "8) (optioneel) registreren als kamer"
if [ -n "$SYSID" ]; then ALSADEV="hw:$CARD" bash "$TOOLS/vc-setup.sh" "$ROOM" "$SYSID" || echo "  (registratie niet bevestigd — zie /tmp/vc-master.log)"
else echo "  Geen system-id — registreer later:  sudo bash $TOOLS/vc-setup.sh \"$ROOM\" <system-id>"; fi

c "9) persistente stack starten (via systemd — overleeft de installer/resume)"
systemctl start vc-connector 2>/dev/null || true
systemctl start vc-ip-watch 2>/dev/null || true
sleep 10

# resume-service opruimen
systemctl disable $RESUME_SVC >/dev/null 2>&1 || true; rm -f /etc/systemd/system/$RESUME_SVC.service; systemctl daemon-reload 2>/dev/null || true

c "KLAAR"
IP=$(ip -4 -o addr show "$(ip route|awk '/^default/{print $5;exit}')" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
echo "Virtuele Connector '$DEVNAME' draait (IP ${IP:-?}), audio -> card $CARD, start automatisch na reboot."
echo "TIP: geef de Pi een vast IP (DHCP-reservering) om her-ontdek-hikjes te voorkomen."
