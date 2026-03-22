#!/bin/bash
# publish-update.sh — Publishes a new flowbit OS ISO to the update server (CT 114)
# Usage: ./publish-update.sh <iso-file> <version> [release-notes]

set -e

UPDATE_SERVER="10.11.10.114"
REMOTE_DIR="/var/www/flowbit-updates"

ISO_FILE="$1"
VERSION="$2"
NOTES="${3:-flowbit OS v$VERSION}"

if [ -z "$ISO_FILE" ] || [ -z "$VERSION" ]; then
    echo "Usage: $0 <iso-file> <version> [release-notes]"
    echo "Example: $0 /tmp/flowbit-2026.03.15-x86_64.iso 3.0.0 'Bug fixes'"
    exit 1
fi

if [ ! -f "$ISO_FILE" ]; then
    echo "Error: ISO file not found: $ISO_FILE"
    exit 1
fi

ISO_NAME="flowbit-os-${VERSION}.iso"
SIZE=$(stat -c%s "$ISO_FILE")
SHA256=$(sha256sum "$ISO_FILE" | awk '{print $1}')
DATE=$(date +%Y-%m-%d)

echo "=== flowbit OS Update Publisher ==="
echo "Version:  $VERSION"
echo "ISO:      $ISO_FILE"
echo "Size:     $((SIZE / 1024 / 1024)) MB"
echo "SHA256:   $SHA256"
echo ""

echo "[1/3] Copying ISO to update server..."
pct push 114 "$ISO_FILE" "${REMOTE_DIR}/isos/${ISO_NAME}"

echo "[2/3] Updating manifest.json..."
pct exec 114 -- bash -c "cat > ${REMOTE_DIR}/manifest.json <<EOF
{
  \"schema_version\": 1,
  \"latest\": {
    \"version\": \"${VERSION}\",
    \"released\": \"${DATE}\",
    \"channel\": \"stable\",
    \"iso\": {
      \"url\": \"https://update.flowbit.ch/isos/${ISO_NAME}\",
      \"size_bytes\": ${SIZE},
      \"sha256\": \"${SHA256}\"
    },
    \"release_notes\": \"${NOTES}\"
  },
  \"minimum_version\": \"1.0.0\"
}
EOF"

echo "[3/3] Verifying..."
pct exec 114 -- curl -s http://localhost/manifest.json | python3 -m json.tool

echo ""
echo "=== Update published successfully ==="
echo "URL: https://update.flowbit.ch/isos/${ISO_NAME}"
