#!/bin/bash
# Extraheert de Raumfeld Connector 2 (device-ID 9, AM33xx/armhf) rootfs uit het
# RFT-firmware-archief. Draai op je Mac; levert connector-rootfs.tar op om naar de Pi te kopieren.
#
#   ./extract-connector-rootfs.sh [pad/naar/RFT-archief.zip] [versie] [uit.tar]
#
# De Connector deelt de rootfs met de One S (universele firmware); het gedrag wordt
# runtime bepaald door /proc/device-tree/model. We draaien 'm straks als "Connector".
set -euo pipefail
ZIP="${1:-$HOME/Downloads/RFT Update-20260902T181717Z-1-001.zip}"
VER="${2:-2.19.3}"
OUT="${3:-$PWD/connector-rootfs.tar}"

[ -f "$ZIP" ] || { echo "Archief niet gevonden: $ZIP"; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo "==> raumfeld-updates.img ($VER) uit archief halen"
unzip -j "$ZIP" "RFT Update/$VER/raumfeld-updates.img" -d "$tmp" >/dev/null
( cd "$tmp" && tar -xf raumfeld-updates.img )
blob=$(tr -d '[]' < "$tmp/9.updates" | head -1 | tr -d ' \t')
echo "==> Connector-2 blob: $blob"
grep -i description "$tmp/9.updates"
echo "==> XZ-decompressie -> rootfs-tar"
python3 - "$tmp/$blob" "$OUT" <<'PY'
import sys, lzma
data = lzma.LZMADecompressor().decompress(open(sys.argv[1], 'rb').read())
open(sys.argv[2], 'wb').write(data)
PY
echo "KLAAR: $OUT ($(du -h "$OUT" | cut -f1)) — dit is een POSIX-tar van de rootfs."
echo "Kopieer naar de Pi en pak uit in bv. /opt/rfconnector:"
echo "  scp \"$OUT\" pi@<pi-ip>:/tmp/"
echo "  ssh pi@<pi-ip> 'sudo mkdir -p /opt/rfconnector && sudo tar -xf /tmp/connector-rootfs.tar -C /opt/rfconnector'"
