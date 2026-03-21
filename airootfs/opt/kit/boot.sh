#!/bin/bash
# flowbit OS Boot Menu

CYAN="\033[1;36m"
WHITE="\033[1;37m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
DIM="\033[2m"
BOLD="\033[1m"
RESET="\033[0m"
TEAL="\033[38;5;43m"

CURRENT_VER=$(cat /etc/flowbit-release 2>/dev/null || echo "0.0.0")
UPDATE_AVAILABLE=""
LATEST_VER=""
ISO_URL=""
ISO_SHA=""
NOTES=""

check_update() {
    MANIFEST=$(curl -sf --connect-timeout 3 --max-time 5 https://update.flowbit.ch/manifest.json 2>/dev/null)
    if [ -n "$MANIFEST" ]; then
        LATEST_VER=$(echo "$MANIFEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('latest',{}).get('version','0.0.0'))" 2>/dev/null)
        ISO_URL=$(echo "$MANIFEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('latest',{}).get('iso',{}).get('url',''))" 2>/dev/null)
        ISO_SHA=$(echo "$MANIFEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('latest',{}).get('iso',{}).get('sha256',''))" 2>/dev/null)
        NOTES=$(echo "$MANIFEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('latest',{}).get('release_notes',''))" 2>/dev/null)
        if [ -n "$LATEST_VER" ] && [ "$LATEST_VER" != "$CURRENT_VER" ] && [ -n "$ISO_URL" ]; then
            UPDATE_AVAILABLE="1"
        fi
    fi
}

do_update() {
    BOOT_PART=""
    BOOT_PART=$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null)
    if [ -z "$BOOT_PART" ]; then
        AUUID=$(cat /proc/cmdline | grep -o 'archisosearchuuid=[^ ]*' | cut -d= -f2)
        [ -n "$AUUID" ] && BOOT_PART=$(blkid -U "$AUUID" 2>/dev/null)
    fi
    if [ -z "$BOOT_PART" ]; then
        BOOT_PART=$(blkid 2>/dev/null | grep -i "FLOWBIT" | head -1 | cut -d: -f1)
    fi
    if [ -z "$BOOT_PART" ]; then
        BOOT_PART=$(lsblk -ndo NAME,TRAN,RM | awk '/usb.*1$/{print "/dev/"$1}' | head -1)
    fi

    BOOT_DEV=""
    if [ -n "$BOOT_PART" ]; then
        PARENT=$(lsblk -ndo PKNAME "$BOOT_PART" 2>/dev/null)
        [ -n "$PARENT" ] && BOOT_DEV="/dev/$PARENT" || BOOT_DEV="$BOOT_PART"
    fi

    if [ -z "$BOOT_DEV" ]; then
        echo -e "\n${RED}    Boot-Device nicht gefunden!${RESET}"
        read -n 1 -s -r -p "    Beliebige Taste..."
        return
    fi

    echo ""
    echo -e "${YELLOW}    Boot-Device: ${BOOT_DEV}${RESET}"
    echo -e "${WHITE}    Lade v${LATEST_VER} herunter...${RESET}"
    echo ""

    curl -f -L --progress-bar -o /tmp/flowbit-update.iso "$ISO_URL"

    if [ $? -ne 0 ] || [ ! -f /tmp/flowbit-update.iso ]; then
        echo -e "\n${RED}    Download fehlgeschlagen!${RESET}"
        read -n 1 -s -r -p "    Beliebige Taste..."
        return
    fi

    echo ""
    echo -e "${DIM}    Prüfe SHA256...${RESET}"
    ACTUAL_SHA=$(sha256sum /tmp/flowbit-update.iso | awk '{print $1}')
    if [ -n "$ISO_SHA" ] && [ "$ACTUAL_SHA" != "$ISO_SHA" ]; then
        echo -e "${RED}    SHA256 Fehler! Abgebrochen.${RESET}"
        rm -f /tmp/flowbit-update.iso
        read -n 1 -s -r -p "    Beliebige Taste..."
        return
    fi
    echo -e "${GREEN}    SHA256 OK${RESET}"
    echo ""
    echo -e "${YELLOW}    Schreibe auf ${BOOT_DEV}... (nicht ausschalten!)${RESET}"

    for mp in $(lsblk -nlo NAME "$BOOT_DEV" 2>/dev/null); do
        umount "/dev/$mp" 2>/dev/null
    done
    umount /run/archiso/bootmnt 2>/dev/null

    dd if=/tmp/flowbit-update.iso of="$BOOT_DEV" bs=4M status=progress oflag=sync 2>&1
    sync
    rm -f /tmp/flowbit-update.iso

    echo ""
    echo -e "${GREEN}    ✓ Update auf v${LATEST_VER} erfolgreich!${RESET}"
    echo -e "${WHITE}    Neustart in 3 Sekunden...${RESET}"
    sleep 3
    reboot -f
}

start_gui() {
    echo ""
    echo -e "${WHITE}    Starte Web-UI...${RESET}"
    python3 /opt/kit/webui/server.py &>/dev/null &
    sleep 1
    if startx 2>/tmp/startx.log; then
        true
    else
        echo ""
        echo -e "${RED}    X11 konnte nicht gestartet werden.${RESET}"
        echo -e "${DIM}    Web-UI: http://$(hostname -I | awk '{print $1}'):8080${RESET}"
        echo ""
        read -n 1 -s -r -p "    Beliebige Taste..."
    fi
}

# ---- Initial update check ----
check_update

# ---- Main menu loop ----
while true; do
    clear
    echo ""
    echo -e "${TEAL}    ┌─────────────────────────────────────────────────────┐${RESET}"
    echo -e "${TEAL}    │${RESET}  ${BOLD}flowbit OS${RESET}  ${DIM}v${CURRENT_VER}${RESET}                                ${TEAL}│${RESET}"
    echo -e "${TEAL}    └─────────────────────────────────────────────────────┘${RESET}"
    echo ""

    # System info line
    HOSTNAME=$(cat /etc/hostname 2>/dev/null || hostname)
    VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null | head -c 20)
    MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null | head -c 25)
    SERIAL=$(cat /sys/class/dmi/id/product_serial 2>/dev/null | head -c 20)
    echo -e "${DIM}    ${VENDOR} ${MODEL} | SN: ${SERIAL}${RESET}"
    echo ""

    # Update status
    if [ "$UPDATE_AVAILABLE" = "1" ]; then
        echo -e "${GREEN}    ● Update verfügbar: v${CURRENT_VER} → v${LATEST_VER}${RESET}"
        echo -e "${DIM}      ${NOTES}${RESET}"
    else
        echo -e "${DIM}    ● System ist aktuell${RESET}"
    fi
    echo ""
    echo -e "${DIM}    ─────────────────────────────────────────────────────${RESET}"
    echo ""

    # Menu items
    echo -e "${TEAL}    [1]${WHITE}  Web-UI starten          ${DIM}— Grafische Oberfläche${RESET}"
    echo -e "${TEAL}    [2]${WHITE}  CLI-Menü                ${DIM}— Klassisches Terminal-Menü${RESET}"
    echo -e "${TEAL}    [3]${WHITE}  Shell                   ${DIM}— Direkt in die Bash${RESET}"
    echo ""
    if [ "$UPDATE_AVAILABLE" = "1" ]; then
        echo -e "${GREEN}    [u]${WHITE}  Update installieren    ${DIM}— v${LATEST_VER} herunterladen & flashen${RESET}"
    fi
    echo -e "${TEAL}    [i]${WHITE}  System-Info             ${DIM}— Hardware-Übersicht${RESET}"
    echo -e "${TEAL}    [r]${WHITE}  Neustart${RESET}"
    echo -e "${TEAL}    [x]${WHITE}  Herunterfahren${RESET}"
    echo ""
    echo -e "${DIM}    ─────────────────────────────────────────────────────${RESET}"
    echo ""
    echo -ne "${WHITE}    Auswahl: ${TEAL}"
    read -n 1 choice
    echo -e "${RESET}"

    case "$choice" in
        1)
            start_gui
            ;;
        2)
            exec /opt/kit/kit.sh
            ;;
        3)
            echo -e "\n${DIM}    Tipp: 'exit' um zum Menü zurückzukehren${RESET}\n"
            bash
            ;;
        u|U)
            if [ "$UPDATE_AVAILABLE" = "1" ]; then
                do_update
            fi
            ;;
        i|I)
            echo ""
            echo -e "${TEAL}    ── Hardware ─────────────────────────────────────${RESET}"
            echo ""
            CPU=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
            MEM=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')
            echo -e "${WHITE}    Hersteller:  ${DIM}${VENDOR}${RESET}"
            echo -e "${WHITE}    Modell:      ${DIM}${MODEL}${RESET}"
            echo -e "${WHITE}    Seriennr.:   ${DIM}${SERIAL}${RESET}"
            echo -e "${WHITE}    CPU:         ${DIM}${CPU}${RESET}"
            echo -e "${WHITE}    RAM:         ${DIM}${MEM}${RESET}"
            echo -e "${WHITE}    Kernel:      ${DIM}$(uname -r)${RESET}"
            echo ""
            echo -e "${TEAL}    ── Datenträger ─────────────────────────────────${RESET}"
            echo ""
            lsblk -d -o NAME,SIZE,MODEL,TRAN 2>/dev/null | while IFS= read -r line; do
                echo -e "${DIM}    ${line}${RESET}"
            done
            echo ""
            echo -e "${TEAL}    ── Netzwerk ────────────────────────────────────${RESET}"
            echo ""
            ip -br addr 2>/dev/null | while IFS= read -r line; do
                echo -e "${DIM}    ${line}${RESET}"
            done
            echo ""
            read -n 1 -s -r -p "    Beliebige Taste..."
            ;;
        r|R)
            echo -e "\n${YELLOW}    Neustart...${RESET}"
            sleep 1
            reboot
            ;;
        x|X)
            echo -e "\n${YELLOW}    Herunterfahren...${RESET}"
            sleep 1
            poweroff
            ;;
        *)
            ;;
    esac
done
