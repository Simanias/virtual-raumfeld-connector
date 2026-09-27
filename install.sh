#!/bin/bash
# Virtual Raumfeld Connector — installer for Raspberry Pi OS 32-bit (armhf) Lite.
#
#   wget -qO- https://raw.githubusercontent.com/Simanias/virtual-raumfeld-connector/main/install.sh | sudo bash
#
# Runs the Raumfeld Connector firmware (userspace) in a chroot, with your own DAC as a full Raumfeld
# renderer. The firmware is fetched from Teufel's official update server during installation.
# Can enable a DAC overlay and then continue automatically after a reboot (--resume).
set -uo pipefail

REPO_RAW="${VC_REPO_RAW:-https://raw.githubusercontent.com/Simanias/virtual-raumfeld-connector/main}"
TOOLS=/opt/virtualtools
ROOT=/opt/rfconnector
HWID=9
UPDATES_HOST="updates.raumfeld.com"
CONF="$TOOLS/install.conf"
RESUME_SVC=vc-install-resume
SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]:-/dev/null}")" 2>/dev/null && pwd || echo /dev/null)"
FILES="connman-stub.py vc-up.sh vc-down.sh vc-master.sh vc-volume-bridge.py vc-ip-watch.sh vc-setup.sh"
SERVICES="vc-connector.service vc-ip-watch.service"
RESUME=0; [ "${1:-}" = "--resume" ] && RESUME=1
[ -n "${VC_DEBUG:-}" ] && set -x    # verbose trace for debugging

c(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
# ask <prompt> <default> [ENV_KEY] : an env var (if set) wins -> non-interactive/headless installs
ask(){ local p="$1" d="${2:-}" k="${3:-}" a=""; if [ -n "$k" ]; then eval "a=\${$k:-}"; [ -n "$a" ] && { echo "$a"; return; }; fi; if [ -r /dev/tty ]; then read -r -p "$p" a </dev/tty || true; fi; echo "${a:-$d}"; }
fetch(){ if [ -f "$SRCDIR/$1" ]; then cp -f "$SRCDIR/$1" "$2"; else curl -fsSL "$REPO_RAW/$1" -o "$2"; fi; }
bootcfg(){ [ -f /boot/firmware/config.txt ] && echo /boot/firmware/config.txt || echo /boot/config.txt; }
# sound cards by NAME (stable across reboots) + kind: external / onboard / hdmi
card_ids(){ aplay -l 2>/dev/null | awk '/^card [0-9]+:/{print $3}' | awk '!s[$0]++'; }
card_desc(){ aplay -l 2>/dev/null | grep -m1 "^card [0-9]*: $1 " | sed -E 's/^card [0-9]+: [^ ]+ \[([^]]*)\].*/\1/'; }
card_kind(){ case "$(aplay -l 2>/dev/null | grep -m1 "^card [0-9]*: $1 " | tr 'A-Z' 'a-z')" in
  *hdmi*|*vc4*) echo hdmi;; *bcm2835*|*headphone*) echo onboard;; *) echo external;; esac; }
auto_card(){ local k c; for k in external onboard hdmi; do for c in $(card_ids); do
  [ "$(card_kind "$c")" = "$k" ] && { echo "$c"; return; }; done; done; }

[ "$(id -u)" = 0 ] || { echo "Run as root:  sudo bash install.sh"; exit 1; }
mkdir -p "$TOOLS"

# ---------- Phase 1: choices + optional DAC overlay + reboot ----------
if [ "$RESUME" = 0 ]; then
  c "0) Checks + base packages"
  arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
  case "$arch" in armhf|armv7l) echo "  arch $arch OK";; *) echo "  WARNING: expected 32-bit armhf, found '$arch' — the rootfs may not run.";; esac
  apt-get update -qq && apt-get install -y -qq alsa-utils curl xz-utils python3-dbus python3-gi coreutils util-linux >/dev/null
  echo "  ok"

  c "1) Choose audio output"
  CARD=""; OVERLAY=""
  if [ -n "${VC_CARD:-}" ]; then CARD="$VC_CARD"; echo "  (env) card $CARD"
  elif [ -n "${VC_OVERLAY:-}" ]; then OVERLAY="$VC_OVERLAY"; CARD=auto; echo "  (env) overlay $OVERLAY"
  else
    i=0; dflt=""; dflt_on=""
    echo "Available audio outputs:"
    for id in $(card_ids); do
      i=$((i+1)); kind=$(card_kind "$id")
      case $kind in onboard) lbl="onboard 3.5mm jack";; hdmi) lbl="HDMI (experimental)";; *) lbl="external DAC/USB";; esac
      printf "  %d) %-16s %s  [%s]\n" "$i" "$id" "$(card_desc "$id")" "$lbl"
      eval "opt_$i=card:$id"
      [ -z "$dflt" ] && [ "$kind" = external ] && dflt=$i
      [ -z "$dflt_on" ] && [ "$kind" = onboard ] && dflt_on=$i
    done
    [ "$i" = 0 ] && echo "  (none)"
    echo "Or enable a DAC HAT (turns on its overlay, followed by an automatic reboot):"
    for ov in "hifiberry-dacplusadc|HiFiBerry DAC+ ADC" "hifiberry-dacplus|HiFiBerry DAC+ / DAC+ Pro" \
              "hifiberry-dac|HiFiBerry DAC (PCM5102A)" "hifiberry-digi|HiFiBerry Digi / Digi+" \
              "iqaudio-dacplus|IQaudio DAC+" "other|Other overlay (type it yourself)"; do
      i=$((i+1)); printf "  %d) %s\n" "$i" "${ov#*|}"; eval "opt_$i=overlay:${ov%%|*}"
    done
    : "${dflt:=${dflt_on:-1}}"                 # default: external DAC, otherwise onboard
    sel=$(ask "Choice [$dflt]: " "$dflt")
    eval "choice=\${opt_$sel:-}"
    case "$choice" in
      card:*)        CARD=${choice#card:} ;;
      overlay:other) OVERLAY=$(ask "Overlay name: " ""); CARD=auto ;;
      overlay:*)     OVERLAY=${choice#overlay:}; CARD=auto ;;
      *)             echo "  invalid choice — choosing automatically"; CARD=auto ;;
    esac
    echo "  selected: ${OVERLAY:+overlay $OVERLAY → }${CARD}"
  fi

  c "2) Name"
  echo "This becomes the name of the room/player in the Raumfeld app (can also be changed later in the app)."
  ROOM=$(ask "Room name [Virtual Connector]: " "${VC_DEVNAME:-Virtual Connector}" VC_ROOM)
  DEVNAME="$ROOM"
  SYSID="${VC_SYSID:-}"      # normally empty: the device adopts the system-id from your host automatically

  # keep the choices for the resume after the reboot
  { echo "DEVNAME=$(printf %q "$DEVNAME")"; echo "ROOM=$(printf %q "$ROOM")"; echo "SYSID=$(printf %q "$SYSID")"
    echo "CARD=$(printf %q "$CARD")"; echo "OVERLAY=$(printf %q "$OVERLAY")"; } > "$CONF"

  BC=$(bootcfg)
  # with a DAC (HAT overlay or external/USB card) switch off the onboard jack, unless VC_KEEP_ONBOARD=1
  if [ -z "${VC_KEEP_ONBOARD:-}" ] && { [ -n "$OVERLAY" ] || { [ "$CARD" != auto ] && [ "$(card_kind "$CARD")" = external ]; }; }; then
    if grep -q "^dtparam=audio=on" "$BC"; then sed -i 's/^dtparam=audio=on/dtparam=audio=off/' "$BC"
    elif ! grep -q "^dtparam=audio=" "$BC"; then echo "dtparam=audio=off" >> "$BC"; fi
    echo "  onboard audio switched off in $BC (you are using a DAC; takes effect after the next reboot)"
  fi
  if [ -n "$OVERLAY" ] && grep -q "^dtoverlay=$OVERLAY" "$BC"; then
    echo "  overlay $OVERLAY is already in $BC — no reboot needed."; OVERLAY=""
  fi
  if [ -n "$OVERLAY" ]; then
    c "3) Enable DAC overlay ($OVERLAY) + reboot"
    echo "dtoverlay=$OVERLAY" >> "$BC"
    echo "  overlay added to $BC."
    # resume service that finishes the installation after the reboot
    cat > /etc/systemd/system/$RESUME_SVC.service <<EOF
[Unit]
Description=Virtual Connector installer resume
After=network-online.target
Wants=network-online.target
ConditionPathExists=$CONF
[Service]
Type=oneshot
TimeoutStartSec=infinity
ExecStartPre=/bin/sleep 15
ExecStart=/bin/bash -c 'curl -fsSL $REPO_RAW/install.sh | bash -s -- --resume'
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable $RESUME_SVC >/dev/null 2>&1
    echo "  the installation continues automatically after the reboot. Rebooting in 5s..."; sleep 5; reboot; exit 0
  fi
fi

# ---------- Phase 2: install (inline, or via the resume after the reboot) ----------
[ -f "$CONF" ] && . "$CONF"
: "${DEVNAME:=Virtual Connector}"; : "${ROOM:=$DEVNAME}"; : "${SYSID:=}"; : "${CARD:=}"; : "${OVERLAY:=}"
# store the chosen audio output by card NAME (after an overlay choice: the new DAC after the reboot)
case "$CARD" in
  ''|auto)  CARD=$(auto_card) ;;
  *[!0-9]*) ;;
  *)        CARD=$(aplay -l 2>/dev/null | awk -v n="$CARD" '$1=="card" && $2==n":"{print $3; exit}') ;;
esac
[ -n "$CARD" ] || CARD=$(auto_card)
printf 'VC_CARD=%q\n' "$CARD" > "$TOOLS/vc.conf"
echo "  audio output: $CARD ($(card_kind "$CARD")) -> $TOOLS/vc.conf"

c "4) Packages + firmware (Connector 2 / HWID $HWID) from Teufel"
apt-get install -y -qq python3-dbus python3-gi xz-utils curl alsa-utils >/dev/null 2>&1 || true
if [ -d "$ROOT/raumfeld" ]; then echo "  rootfs already present — skipping."; else
  mkdir -p "$ROOT"
  hash=$(curl -fsSL "https://$UPDATES_HOST/$HWID.updates" | tr -d '[] \t\r' | head -1)
  [ -n "$hash" ] || { echo "  could not read the firmware index"; exit 1; }
  echo "  blob $hash — downloading + extracting ..."
  curl -fsSL "https://$UPDATES_HOST/$hash" | xz -d | tar -x -C "$ROOT"
fi

c "5) Tooling + services"
for f in $FILES; do fetch "$f" "$TOOLS/$f"; done
chmod +x "$TOOLS"/*.sh
for s in $SERVICES; do fetch "$s" "/etc/systemd/system/$s"; done

c "6) Name + model label (audio -> $CARD)"
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
  [ -f "$LIB.new" ] && chmod --reference="$LIB" "$LIB.new" && mv "$LIB.new" "$LIB" && echo "  model label -> Virtual Connector"
fi
# no update block (anymore): it made the setup hang, and we already install the newest firmware
sed -i "/$UPDATES_HOST/d" "$ROOT/etc/hosts" 2>/dev/null || true

c "7) Enable services"
systemctl daemon-reload; systemctl enable vc-connector vc-ip-watch >/dev/null 2>&1 || true

c "8) Register as a room (the system-id is adopted automatically from your Raumfeld host)"
if [ -f "$ROOT/var/raumfeld-1.0/device-role.json" ]; then
  echo "  already registered — skipping"
else
  bash "$TOOLS/vc-setup.sh" "$ROOM" "$SYSID" \
    || echo "  (registration not confirmed — retry later:  sudo bash $TOOLS/vc-setup.sh \"$ROOM\")"
fi

c "9) Start the persistent stack (via systemd — survives the installer/resume)"
systemctl start vc-connector 2>/dev/null || true
systemctl start vc-ip-watch 2>/dev/null || true
sleep 10

# clean up the resume service
systemctl disable $RESUME_SVC >/dev/null 2>&1 || true; rm -f /etc/systemd/system/$RESUME_SVC.service; systemctl daemon-reload 2>/dev/null || true

c "DONE"
IP=$(ip -4 -o addr show "$(ip route|awk '/^default/{print $5;exit}')" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
echo "Virtual Connector '$DEVNAME' is running (IP ${IP:-?}), audio -> $CARD ($(card_kind "$CARD")), starts automatically after a reboot."
echo "Different audio output later? Change VC_CARD in $TOOLS/vc.conf and run: sudo systemctl restart vc-connector"
echo "TIP: give the Pi a fixed IP (DHCP reservation) to avoid rediscovery hiccups."
