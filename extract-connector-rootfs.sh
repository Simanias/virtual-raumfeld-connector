#!/bin/bash
# Optional/offline alternative to the installer's download: extracts the Raumfeld Connector 2
# (device id 9, AM33xx/armhf) rootfs from a raumfeld-updates.img inside an RFT firmware archive.
# Run it on any machine with python3; it produces connector-rootfs.tar to copy to the Pi.
#
#   ./extract-connector-rootfs.sh <path/to/RFT-archive.zip> [version] [out.tar]
#
# The Connector shares its rootfs with the One S (universal firmware); the behaviour is decided at
# runtime by /proc/device-tree/model. We run it as a "Connector".
set -euo pipefail
ZIP="${1:?Usage: extract-connector-rootfs.sh <RFT-archive.zip> [version] [out.tar]}"
VER="${2:-2.19.3}"
OUT="${3:-$PWD/connector-rootfs.tar}"

[ -f "$ZIP" ] || { echo "Archive not found: $ZIP"; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo "==> extracting raumfeld-updates.img ($VER) from the archive"
unzip -j "$ZIP" "RFT Update/$VER/raumfeld-updates.img" -d "$tmp" >/dev/null
( cd "$tmp" && tar -xf raumfeld-updates.img )
blob=$(tr -d '[]' < "$tmp/9.updates" | head -1 | tr -d ' \t')
echo "==> Connector 2 blob: $blob"
grep -i description "$tmp/9.updates"
echo "==> XZ decompression -> rootfs tar"
python3 - "$tmp/$blob" "$OUT" <<'PY'
import sys, lzma
data = lzma.LZMADecompressor().decompress(open(sys.argv[1], 'rb').read())
open(sys.argv[2], 'wb').write(data)
PY
echo "DONE: $OUT ($(du -h "$OUT" | cut -f1)) — a POSIX tar of the rootfs."
echo "Copy it to the Pi and extract it into /opt/rfconnector:"
echo "  scp \"$OUT\" pi@<pi-ip>:/tmp/"
echo "  ssh pi@<pi-ip> 'sudo mkdir -p /opt/rfconnector && sudo tar -xf /tmp/connector-rootfs.tar -C /opt/rfconnector'"
