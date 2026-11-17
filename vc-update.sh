#!/bin/bash
# Firmware update for the Virtual Raumfeld Connector.
# A real device flashes the update with a kexec'd update kernel; that can't work on a Pi. Instead the new
# firmware is extracted next to the current one, the device's identity and settings (var/raumfeld-1.0)
# are carried over, the folders are swapped and the stack is restarted (vc-up.sh prepares the fresh
# rootfs). The previous firmware stays in /opt/rfconnector.prev for --rollback.
#
#   sudo bash vc-update.sh                  update to the newest firmware from Teufel's server
#   sudo bash vc-update.sh <update file>    install this update file (as downloaded by the firmware)
#   sudo bash vc-update.sh --request        install what the firmware asked for (started by the watcher
#                                           when you update the system in the Raumfeld app)
#   sudo bash vc-update.sh --check          only download/extract and check, change nothing
#   sudo bash vc-update.sh --rollback       go back to the previous firmware
set -u
TOOLS=${TOOLS:-/opt/virtualtools}
ROOT=${ROOT:-/opt/rfconnector}
NEW="$ROOT.new"; PREV="$ROOT.prev"
HWID=9
UPDATES_HOST="updates.raumfeld.com"
REQ="$ROOT/tmp/vc-update-request"          # written by our kexec stand-in (see vc-up.sh)
log(){ echo "vc-update: $*"; logger -t vc-update -- "$*" 2>/dev/null || true; }
die(){ log "!! $*"; rm -rf "$NEW"
  # the firmware is waiting in our kexec stand-in: restart it on the current firmware
  [ -f "$REQ" ] && { rm -f "$REQ"; systemctl restart vc-connector; }
  exit 1; }
[ "$(id -u)" = 0 ] || { echo "Run as root (sudo)."; exit 1; }
ver(){ cat "$1/etc/raumfeld-version" 2>/dev/null; }
mounts_under(){ awk -v r="$1/" 'index($2, r) == 1 {print $2}' /proc/mounts; }
started(){ for i in $(seq 1 "${1:-90}"); do grep -q "apps-running" /tmp/vc-master.log 2>/dev/null && return 0; sleep 2; done; return 1; }

if [ "${1:-}" = "--rollback" ]; then
  [ -d "$PREV" ] || { echo "No previous firmware ($PREV)."; exit 1; }
  log "rolling back: $(ver "$ROOT") -> $(ver "$PREV")"
  systemctl stop vc-connector
  [ -z "$(mounts_under "$ROOT")" ] || die "still mounted under $ROOT — not swapping"
  rm -rf "$ROOT.failed"; mv "$ROOT" "$ROOT.failed" && mv "$PREV" "$ROOT" || die "swap failed"
  cp -a "$ROOT.failed/var/raumfeld-1.0/." "$ROOT/var/raumfeld-1.0/"   # keep settings changed since
  systemctl start vc-connector
  started && log "rolled back to $(ver "$ROOT")" || log "stack not up yet — see /tmp/vc-master.log"
  exit 0
fi

CHECK=0; BLOB=""
case "${1:-}" in
  --check)   CHECK=1 ;;
  --request) [ -f "$REQ" ] || { echo "No update request."; exit 1; }
             f=$(sed -n 's/.*raumfeld-update=\([^ ,]*\).*/\1/p' "$REQ" | head -1)
             [ -n "$f" ] && [ -f "$ROOT$f" ] && BLOB="$ROOT$f"
             [ -n "$BLOB" ] || BLOB=$(ls -t "$ROOT"/update/[0-9a-f]* 2>/dev/null | grep -E '/[0-9a-f]{64}$' | head -1)
             [ -n "$BLOB" ] || die "update requested, but no update file found" ;;
  "") ;;
  *)         BLOB="$1"; [ -f "$BLOB" ] || { echo "No such file: $BLOB"; exit 1; } ;;
esac

if [ -z "$BLOB" ]; then                     # newest firmware from Teufel's update server
  idx=$(curl -fsSL --max-time 20 "https://$UPDATES_HOST/$HWID.updates") || die "could not read the firmware index"
  hash=$(printf '%s\n' "$idx" | tr -d '[] \t\r' | grep -m1 -E '^[0-9a-f]{64}$')
  newv=$(printf '%s\n' "$idx" | sed -n 's/^[[:space:]]*version=//p' | head -1)
  [ -n "$hash" ] || die "could not read the firmware index"
  if [ "$CHECK" = 0 ] && [ -n "$newv" ] && [ "$newv" = "$(ver "$ROOT")" ]; then
    log "already up to date ($newv)"; exit 0
  fi
  BLOB="$ROOT/update/$hash"
  if [ ! -f "$BLOB" ]; then
    log "downloading firmware $newv ..."; mkdir -p "$ROOT/update"
    curl -fsSL -o "$BLOB.part" "https://$UPDATES_HOST/$hash" && mv "$BLOB.part" "$BLOB" || { rm -f "$BLOB.part"; die "download failed"; }
  fi
fi

# update files are named after their SHA-256: verify it
name=$(basename "$BLOB")
if printf '%s' "$name" | grep -qE '^[0-9a-f]{64}$'; then
  [ "$(sha256sum "$BLOB" | cut -d' ' -f1)" = "$name" ] || die "checksum mismatch: $BLOB"
fi
log "extracting $(basename "$BLOB") ..."
rm -rf "$NEW"; mkdir -p "$NEW"
xz -d < "$BLOB" | tar -x -C "$NEW" || die "extracting failed"
newv=$(ver "$NEW"); [ -n "$newv" ] && [ -x "$NEW/raumfeld/master-process/master-process" ] || die "not a Connector firmware"
python3 "$TOOLS/vc-renderer-libs.py" "$NEW" /tmp/vc-update-libcheck >/dev/null 2>&1 \
  && log "renderer patches apply to $newv" \
  || log "note: renderer patches do not apply to $newv — the renderer will run in basic mode (no EQ/LED)"
rm -rf /tmp/vc-update-libcheck
if [ "$CHECK" = 1 ]; then
  log "check ok: firmware $newv (installed: $(ver "$ROOT")) — nothing changed"; rm -rf "$NEW"; exit 0
fi

log "updating firmware $(ver "$ROOT") -> $newv"
systemctl stop vc-connector
[ -z "$(mounts_under "$ROOT")" ] || { systemctl start vc-connector; die "still mounted under $ROOT — not swapping"; }
cp -a "$ROOT/var/raumfeld-1.0" "$NEW/var/" || { systemctl start vc-connector; die "could not copy the device settings"; }
rm -rf "$PREV"
mv "$ROOT" "$PREV" && mv "$NEW" "$ROOT" || { [ -d "$ROOT" ] || mv "$PREV" "$ROOT"; systemctl start vc-connector; die "swap failed"; }
rm -f "$PREV"/update/* "$PREV/tmp/vc-update-request"          # the old copy doesn't need the update files
systemctl start vc-connector                                     # vc-up.sh prepares the fresh rootfs
if started 120; then
  log "firmware $newv is running (previous firmware kept for:  sudo bash $TOOLS/vc-update.sh --rollback)"
else
  log "!! the stack did not come up within 4 minutes — see /tmp/vc-master.log; back to the previous firmware with:  sudo bash $TOOLS/vc-update.sh --rollback"
  exit 1
fi
