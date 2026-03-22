#!/bin/bash
# =============================================================================
#  flowbit OS — Shared Helper Functions
#  Gemeinsame Funktionen fuer alle Module
# =============================================================================

# ─── Farben ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Boot Device Detection ───────────────────────────────────────────────────
get_boot_device() {
    lsblk -no PKNAME $(findmnt -n -o SOURCE /) 2>/dev/null | head -1
}

# ─── USB Storage Detection ───────────────────────────────────────────────────
find_usb_storage() {
    for mp in /mnt/kit-storage /mnt/usb* /run/media/*/*; do
        [[ -w "$mp" ]] && echo "$mp" && return 0
    done
    return 1
}

# ─── Safe Disk Selection (excludes boot device) ─────────────────────────────
select_disk() {
    local prompt="${1:-Disk auswaehlen}"
    local boot_dev
    boot_dev=$(get_boot_device)
    local disks=()
    local i=1

    for disk in /dev/sd? /dev/nvme?n?; do
        [[ ! -b "$disk" ]] && continue
        local dev_name=$(basename "$disk")
        [[ "$dev_name" == "$boot_dev" ]] && continue
        local size=$(lsblk -dno SIZE "$disk" 2>/dev/null)
        local model=$(lsblk -dno MODEL "$disk" 2>/dev/null)
        echo -e "  ${CYAN}[$i]${NC} $disk — $size — $model"
        disks+=("$disk")
        ((i++))
    done

    if [[ ${#disks[@]} -eq 0 ]]; then
        echo -e "${RED}Keine Disks gefunden (Boot-Device ausgeschlossen)${NC}"
        return 1
    fi

    read -rp "$prompt [1-$((i-1))]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )); then
        echo "${disks[$((choice-1))]}"
        return 0
    fi
    return 1
}

# ─── Session Logging ─────────────────────────────────────────────────────────
log_session() {
    local action="$1"
    local persist_dir="/mnt/kit-storage"
    [[ ! -d "$persist_dir" ]] && persist_dir="/tmp/ittools"
    mkdir -p "$persist_dir"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $action" >> "$persist_dir/session.log"
}
