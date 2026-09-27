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
# audio-kaarten op NAAM (stabiel over reboots heen) + soort: extern / onboard / hdmi
card_ids(){ aplay -l 2>/dev/null | awk '/^card [0-9]+:/{print $3}' | awk '!s[$0]++'; }
card_desc(){ aplay -l 2>/dev/null | grep -m1 "^card [0-9]*: $1 " | sed -E 's/^card [0-9]+: [^ ]+ \[([^]]*)\].*/\1/'; }
card_kind(){ case "$(aplay -l 2>/dev/null | grep -m1 "^card [0-9]*: $1 " | tr 'A-Z' 'a-z')" in
  *hdmi*|*vc4*) echo hdmi;; *bcm2835*|*headphone*) echo onboard;; *) echo extern;; esac; }
auto_card(){ local k c; for k in extern onboard hdmi; do for c in $(card_ids); do
  [ "$(card_kind "$c")" = "$k" ] && { echo "$c"; return; }; done; done; }

[ "$(id -u)" = 0 ] || { echo "Draai als root:  sudo bash install.sh"; exit 1; }
mkdir -p "$TOOLS"

# ---------- Fase 1: keuzes + eventueel DAC-overlay + reboot ----------
if [ "$RESUME" = 0 ]; then
  c "0) Checks + basispakketten"
  arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
  case "$arch" in armhf|armv7l) echo "  arch $arch OK";; *) echo "  LET OP: verwacht 32-bit armhf; '$arch' gevonden — rootfs draait mogelijk niet.";; esac
  apt-get update -qq && apt-get install -y -qq alsa-utils curl xz-utils python3-dbus python3-gi coreutils util-linux >/dev/null
  echo "  ok"

  c "1) Audio-uitgang kiezen"
  CARD=""; OVERLAY=""
  if [ -n "${VC_CARD:-}" ]; then CARD="$VC_CARD"; echo "  (env) kaart $CARD"
  elif [ -n "${VC_OVERLAY:-}" ]; then OVERLAY="$VC_OVERLAY"; CARD=auto; echo "  (env) overlay $OVERLAY"
  else
    i=0; dflt=""; dflt_on=""
    echo "Aanwezige audio-uitgangen:"
    for id in $(card_ids); do
      i=$((i+1)); kind=$(card_kind "$id")
      case $kind in onboard) lbl="onboard 3,5mm-jack";; hdmi) lbl="HDMI (experimenteel)";; *) lbl="externe DAC/USB";; esac
      printf "  %d) %-16s %s  [%s]\n" "$i" "$id" "$(card_desc "$id")" "$lbl"
      eval "opt_$i=card:$id"
      [ -z "$dflt" ] && [ "$kind" = extern ] && dflt=$i
      [ -z "$dflt_on" ] && [ "$kind" = onboard ] && dflt_on=$i
    done
    [ "$i" = 0 ] && echo "  (geen)"
    echo "Of een DAC-HAT inschakelen (zet de overlay aan; daarna automatische reboot):"
    for ov in "hifiberry-dacplusadc|HiFiBerry DAC+ ADC" "hifiberry-dacplus|HiFiBerry DAC+ / DAC+ Pro" \
              "hifiberry-dac|HiFiBerry DAC (PCM5102A)" "hifiberry-digi|HiFiBerry Digi / Digi+" \
              "iqaudio-dacplus|IQaudio DAC+" "other|Andere overlay (zelf typen)"; do
      i=$((i+1)); printf "  %d) %s\n" "$i" "${ov#*|}"; eval "opt_$i=overlay:${ov%%|*}"
    done
    : "${dflt:=${dflt_on:-1}}"                 # standaard: externe DAC, anders onboard
    sel=$(ask "Keuze [$dflt]: " "$dflt")
    eval "choice=\${opt_$sel:-}"
    case "$choice" in
      card:*)        CARD=${choice#card:} ;;
      overlay:other) OVERLAY=$(ask "Overlay-naam: " ""); CARD=auto ;;
      overlay:*)     OVERLAY=${choice#overlay:}; CARD=auto ;;
      *)             echo "  ongeldige keuze — automatisch kiezen"; CARD=auto ;;
    esac
    echo "  gekozen: ${OVERLAY:+overlay $OVERLAY → }${CARD}"
  fi

  c "2) Overige keuzes"
  DEVNAME=$(ask "Device-naam [Virtual Connector]: " "Virtual Connector" VC_DEVNAME)
  ROOM=$(ask "Kamernaam in Raumfeld [$DEVNAME]: " "$DEVNAME" VC_ROOM)
  echo "system-id = de systeem-UUID van je Raumfeld-systeem (op een toestel: /var/raumfeld-1.0/system-id)."
  SYSID=$(ask "Raumfeld system-id (leeg = later/automatisch): " "" VC_SYSID)

  # keuzes bewaren voor (resume na) reboot
  { echo "DEVNAME=$(printf %q "$DEVNAME")"; echo "ROOM=$(printf %q "$ROOM")"; echo "SYSID=$(printf %q "$SYSID")"
    echo "CARD=$(printf %q "$CARD")"; echo "OVERLAY=$(printf %q "$OVERLAY")"; } > "$CONF"

  BC=$(bootcfg)
  if [ -n "$OVERLAY" ] && grep -q "^dtoverlay=$OVERLAY" "$BC"; then
    echo "  overlay $OVERLAY staat al in $BC — geen reboot nodig."; OVERLAY=""
  fi
  if [ -n "$OVERLAY" ]; then
    c "3) DAC-overlay aanzetten ($OVERLAY) + reboot"
    echo "dtoverlay=$OVERLAY" >> "$BC"
    echo "  overlay in $BC gezet (onboard audio blijft beschikbaar)."
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
# gekozen audio-uitgang vastleggen op kaartNAAM (bij overlay-keuze: de nieuwe DAC na de reboot)
case "$CARD" in
  ''|auto)  CARD=$(auto_card) ;;
  *[!0-9]*) ;;
  *)        CARD=$(aplay -l 2>/dev/null | awk -v n="$CARD" '$1=="card" && $2==n":"{print $3; exit}') ;;
esac
[ -n "$CARD" ] || CARD=$(auto_card)
printf 'VC_CARD=%q\n' "$CARD" > "$TOOLS/vc.conf"
echo "  audio-uitgang: $CARD ($(card_kind "$CARD")) -> $TOOLS/vc.conf"

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
if [ -n "$SYSID" ]; then bash "$TOOLS/vc-setup.sh" "$ROOM" "$SYSID" || echo "  (registratie niet bevestigd — zie /tmp/vc-master.log)"
else echo "  Geen system-id — registreer later:  sudo bash $TOOLS/vc-setup.sh \"$ROOM\" <system-id>"; fi

c "9) persistente stack starten (via systemd — overleeft de installer/resume)"
systemctl start vc-connector 2>/dev/null || true
systemctl start vc-ip-watch 2>/dev/null || true
sleep 10

# resume-service opruimen
systemctl disable $RESUME_SVC >/dev/null 2>&1 || true; rm -f /etc/systemd/system/$RESUME_SVC.service; systemctl daemon-reload 2>/dev/null || true

c "KLAAR"
IP=$(ip -4 -o addr show "$(ip route|awk '/^default/{print $5;exit}')" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
echo "Virtuele Connector '$DEVNAME' draait (IP ${IP:-?}), audio -> $CARD ($(card_kind "$CARD")), start automatisch na reboot."
echo "Andere audio-uitgang later? Pas VC_CARD aan in $TOOLS/vc.conf en: sudo systemctl restart vc-connector"
echo "TIP: geef de Pi een vast IP (DHCP-reservering) om her-ontdek-hikjes te voorkomen."
