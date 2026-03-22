#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/archiso-kit-work"
OUT_DIR="/root"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== flowbit OS Build ===${NC}"

# Read current version
VERSION=$(cat "$SCRIPT_DIR/airootfs/etc/flowbit-release" 2>/dev/null || echo "0.0.0")
echo -e "Aktuelle Version: ${GREEN}${VERSION}${NC}"

# Optional: bump version
if [[ "${1:-}" == "--bump" ]]; then
    IFS='.' read -r major minor patch <<< "$VERSION"
    patch=$((patch + 1))
    NEW_VERSION="$major.$minor.$patch"
    echo "$NEW_VERSION" | sudo tee "$SCRIPT_DIR/airootfs/etc/flowbit-release" > /dev/null
    echo -e "Neue Version: ${GREEN}${NEW_VERSION}${NC}"
    VERSION="$NEW_VERSION"
fi

# Sync version to server.py fallback
sudo sed -i "s/FLOWBIT_VERSION = \".*\"/FLOWBIT_VERSION = \"$VERSION\"/" \
    "$SCRIPT_DIR/airootfs/opt/kit/webui/server.py"

# Clean previous build
echo -e "${CYAN}Cleanup...${NC}"
sudo rm -rf "$WORK_DIR"

# Build ISO
echo -e "${CYAN}Building ISO...${NC}"
sudo mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$SCRIPT_DIR"

# Show result
ISO=$(ls -t "$OUT_DIR"/flowbit-*.iso 2>/dev/null | head -1)
if [[ -n "$ISO" ]]; then
    SIZE=$(du -h "$ISO" | cut -f1)
    SHA=$(sha256sum "$ISO" | cut -d' ' -f1)
    echo -e "${GREEN}=== Build erfolgreich ===${NC}"
    echo -e "ISO:     $ISO"
    echo -e "Grösse:  $SIZE"
    echo -e "SHA256:  $SHA"
    echo -e "Version: $VERSION"
else
    echo -e "${RED}Build fehlgeschlagen!${NC}"
    exit 1
fi
