#!/bin/bash
# flowbit OS Auto-Mount & Data Partition Setup
# Runs at boot to:
# 1. Create a data partition on boot USB if space available
# 2. Auto-mount all USB storage devices

DATA_LABEL="ITTOOLS-DATA"
DATA_MOUNT="/mnt/data"
USB_MOUNT_BASE="/mnt/usb"

mkdir -p "$DATA_MOUNT" "$USB_MOUNT_BASE"

# --- Find the boot USB device ---
get_boot_device() {
    # Find which device we booted from (the ISO device)
    local boot_dev=""
    # Check kernel cmdline for the boot device
    boot_dev=$(grep -oP 'dev/\K[a-z]+' /proc/cmdline 2>/dev/null | head -1)
    if [ -z "$boot_dev" ]; then
        # Find device with iso9660/vfat that contains our ISO
        boot_dev=$(lsblk -nro NAME,FSTYPE,LABEL | grep -iE 'iso9660|KIT|ARCH' | head -1 | awk '{print $1}' | sed 's/[0-9]*$//')
    fi
    if [ -z "$boot_dev" ]; then
        # Fallback: find removable device with iso9660
        for dev in $(lsblk -dnro NAME,RM | awk '$2==1{print $1}'); do
            if lsblk -nro FSTYPE /dev/${dev}* 2>/dev/null | grep -q iso9660; then
                boot_dev="$dev"
                break
            fi
        done
    fi
    echo "$boot_dev"
}

# --- Create data partition on boot USB ---
setup_data_partition() {
    local boot_disk="$1"
    [ -z "$boot_disk" ] && return

    # Check if data partition already exists
    if lsblk -nro LABEL /dev/${boot_disk}* 2>/dev/null | grep -q "$DATA_LABEL"; then
        # Already exists, just mount it
        local data_part=$(lsblk -nro NAME,LABEL /dev/${boot_disk}* | grep "$DATA_LABEL" | awk '{print $1}')
        if [ -n "$data_part" ]; then
            mount /dev/$data_part "$DATA_MOUNT" 2>/dev/null
            echo "Data partition mounted: /dev/$data_part -> $DATA_MOUNT"
        fi
        return
    fi

    # Get disk size and used space
    local disk_size=$(blockdev --getsize64 /dev/$boot_disk 2>/dev/null)
    [ -z "$disk_size" ] || [ "$disk_size" -eq 0 ] && return

    # Find last partition end
    local last_end=$(parted -ms /dev/$boot_disk print 2>/dev/null | tail -1 | cut -d: -f3 | sed 's/[^0-9]//g')
    [ -z "$last_end" ] && return

    local disk_size_mb=$((disk_size / 1048576))
    local last_end_mb=$((last_end / 1048576 + 1))
    local free_mb=$((disk_size_mb - last_end_mb))

    # Need at least 500MB free to bother
    if [ "$free_mb" -lt 500 ]; then
        echo "Nicht genug Platz fuer Daten-Partition (${free_mb}MB frei, min 500MB)"
        return
    fi

    echo "Erstelle Daten-Partition (${free_mb}MB) auf /dev/${boot_disk}..."

    # Find next partition number
    local next_num=$(( $(lsblk -nro NAME /dev/${boot_disk}* | wc -l) ))

    # Create partition with remaining space
    parted -s /dev/$boot_disk mkpart primary ext4 ${last_end_mb}MiB 100% 2>/dev/null
    sleep 2

    # Find the new partition
    local new_part=""
    for p in $(lsblk -nro NAME /dev/${boot_disk}* 2>/dev/null); do
        if ! blkid /dev/$p 2>/dev/null | grep -qE 'iso9660|vfat|FAT'; then
            if [ "$(lsblk -nro FSTYPE /dev/$p 2>/dev/null)" = "" ]; then
                new_part="$p"
            fi
        fi
    done

    if [ -z "$new_part" ]; then
        # Try common naming
        new_part="${boot_disk}3"
        [ ! -b "/dev/$new_part" ] && new_part="${boot_disk}4"
        [ ! -b "/dev/$new_part" ] && return
    fi

    # Format with ext4
    mkfs.ext4 -L "$DATA_LABEL" -q /dev/$new_part 2>/dev/null
    sleep 1

    # Mount
    mount /dev/$new_part "$DATA_MOUNT" 2>/dev/null

    # Create default directories
    mkdir -p "$DATA_MOUNT/Exports" "$DATA_MOUNT/BIOS_Settings" "$DATA_MOUNT/Backups"

    echo "Daten-Partition erstellt und gemountet: /dev/$new_part -> $DATA_MOUNT (${free_mb}MB)"
}

# --- Auto-mount other USB devices ---
mount_usb_devices() {
    local boot_disk="$1"
    local idx=1

    for dev in $(lsblk -dnro NAME,RM 2>/dev/null | awk '$2==1{print $1}'); do
        # Skip the boot device
        [ "$dev" = "$boot_disk" ] && continue

        for part in $(lsblk -nro NAME,TYPE /dev/${dev}* 2>/dev/null | awk '$2=="part"{print $1}'); do
            local fstype=$(lsblk -nro FSTYPE /dev/$part 2>/dev/null)
            [ -z "$fstype" ] && continue

            local label=$(lsblk -nro LABEL /dev/$part 2>/dev/null)
            local mountpoint="${USB_MOUNT_BASE}/${label:-usb${idx}}"
            mkdir -p "$mountpoint"

            if ! mountpoint -q "$mountpoint" 2>/dev/null; then
                mount /dev/$part "$mountpoint" 2>/dev/null && \
                    echo "USB gemountet: /dev/$part -> $mountpoint ($fstype)"
            fi
            idx=$((idx + 1))
        done
    done
}

# --- Main ---
echo "flowbit OS Storage Setup..."
BOOT_DISK=$(get_boot_device)
echo "Boot-Device: /dev/${BOOT_DISK:-nicht erkannt}"

setup_data_partition "$BOOT_DISK"
mount_usb_devices "$BOOT_DISK"

# Summary
echo ""
echo "=== Speicher ==="
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null | grep -v loop
echo ""
