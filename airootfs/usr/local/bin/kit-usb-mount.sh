#!/bin/bash
ACTION="$1"
DEV="$2"
USB_BASE="/mnt/usb"
mkdir -p "$USB_BASE"

if [ "$ACTION" = "add" ]; then
    LABEL=$(lsblk -nro LABEL /dev/$DEV 2>/dev/null)
    FSTYPE=$(lsblk -nro FSTYPE /dev/$DEV 2>/dev/null)
    [ -z "$FSTYPE" ] && exit 0
    [ "$LABEL" = "ITTOOLS-DATA" ] && exit 0
    MPOINT="${USB_BASE}/${LABEL:-$DEV}"
    mkdir -p "$MPOINT"
    mount /dev/$DEV "$MPOINT" 2>/dev/null
elif [ "$ACTION" = "remove" ]; then
    umount /dev/$DEV 2>/dev/null
fi
