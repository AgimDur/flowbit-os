#!/bin/bash
# flowbit OS Boot Menu v3

CYAN="\033[1;36m"
WHITE="\033[1;37m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
DIM="\033[2m"
BOLD="\033[1m"
RESET="\033[0m"
TEAL="\033[38;5;43m"

CURRENT_VER=$(cat /etc/flowbit-release 2>/dev/null)
[ -z "$CURRENT_VER" ] && CURRENT_VER="0.0.0"

UPDATE_AVAILABLE=""
LATEST_VER=""
ISO_URL=""
ISO_SHA=""
NOTES=""

get_ip() {
    hostname -I 2>/dev/null | awk '{print $1}'
}

check_update() {
    UPDATE_AVAILABLE=""
    echo -ne "${DIM}    Prüfe...${RESET}"
    # Start NM if needed
    if command -v nmcli &>/dev/null && ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
        systemctl start NetworkManager 2>/dev/null
        sleep 2
    fi
    MANIFEST=$(curl -sf --connect-timeout 5 --max-time 10 https://update.flowbit.ch/manifest.json 2>/dev/null)
    if [ -z "$MANIFEST" ]; then
        echo -e "\r${RED}    Kein Internet oder Update-Server nicht erreichbar.${RESET}"
        sleep 2
        return
    fi
    LATEST_VER=$(echo "$MANIFEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('latest',{}).get('version','0.0.0'))" 2>/dev/null)
    ISO_URL=$(echo "$MANIFEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('latest',{}).get('iso',{}).get('url',''))" 2>/dev/null)
    ISO_SHA=$(echo "$MANIFEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('latest',{}).get('iso',{}).get('sha256',''))" 2>/dev/null)
    NOTES=$(echo "$MANIFEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('latest',{}).get('release_notes',''))" 2>/dev/null)
    if [ -n "$LATEST_VER" ] && [ "$LATEST_VER" != "$CURRENT_VER" ] && [ -n "$ISO_URL" ]; then
        UPDATE_AVAILABLE="1"
        echo -e "\r${GREEN}    Update verfügbar: v${CURRENT_VER} → v${LATEST_VER}            ${RESET}"
        echo -e "${DIM}      ${NOTES}${RESET}"
    else
        echo -e "\r${TEAL}    System ist aktuell (v${CURRENT_VER}).                    ${RESET}"
    fi
    sleep 1
}

do_update() {
    # Find boot device
    BOOT_PART=""
    BOOT_PART=$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null)
    [ -z "$BOOT_PART" ] && {
        AUUID=$(grep -o 'archisosearchuuid=[^ ]*' /proc/cmdline 2>/dev/null | cut -d= -f2)
        [ -n "$AUUID" ] && BOOT_PART=$(blkid -U "$AUUID" 2>/dev/null)
    }
    [ -z "$BOOT_PART" ] && BOOT_PART=$(blkid 2>/dev/null | grep -i "FLOWBIT" | head -1 | cut -d: -f1)
    [ -z "$BOOT_PART" ] && BOOT_PART=$(lsblk -ndo NAME,TRAN,RM 2>/dev/null | awk '/usb/{print "/dev/"$1}' | head -1)

    BOOT_DEV=""
    if [ -n "$BOOT_PART" ]; then
        PARENT=$(lsblk -ndo PKNAME "$BOOT_PART" 2>/dev/null)
        [ -n "$PARENT" ] && BOOT_DEV="/dev/$PARENT" || BOOT_DEV="$BOOT_PART"
    fi
    [ "$BOOT_DEV" = "/dev/" ] && BOOT_DEV=""

    if [ -z "$BOOT_DEV" ]; then
        echo -e "\n${RED}    Kein Boot-Device gefunden!${RESET}"
        read -n 1 -s -r -p "    Beliebige Taste..."
        return
    fi

    DEV_SIZE=$(lsblk -ndo SIZE "$BOOT_DEV" 2>/dev/null)
    DEV_MODEL=$(lsblk -ndo MODEL "$BOOT_DEV" 2>/dev/null)
    echo ""
    echo -e "${YELLOW}    Update: v${CURRENT_VER} → v${LATEST_VER}${RESET}"
    echo -e "${YELLOW}    Ziel:   ${BOOT_DEV} (${DEV_SIZE} ${DEV_MODEL})${RESET}"
    echo -e "${RED}    ACHTUNG: Stick wird überschrieben!${RESET}"
    echo ""
    echo -ne "${WHITE}    Fortfahren? [j/n]: ${TEAL}"
    read -n 1 CONFIRM
    echo -e "${RESET}"
    [ "$CONFIRM" != "j" ] && [ "$CONFIRM" != "J" ] && return

    echo ""
    echo -e "${WHITE}    1/3 Lade ISO...${RESET}"
    curl -f -L --progress-bar -o /tmp/flowbit-update.iso "$ISO_URL"
    if [ $? -ne 0 ] || [ ! -f /tmp/flowbit-update.iso ]; then
        echo -e "${RED}    Download fehlgeschlagen!${RESET}"
        read -n 1 -s -r -p "    Beliebige Taste..."
        return
    fi

    echo -e "${WHITE}    2/3 Prüfe SHA256...${RESET}"
    ACTUAL_SHA=$(sha256sum /tmp/flowbit-update.iso | awk '{print $1}')
    if [ -n "$ISO_SHA" ] && [ "$ACTUAL_SHA" != "$ISO_SHA" ]; then
        echo -e "${RED}    SHA256 Fehler!${RESET}"
        rm -f /tmp/flowbit-update.iso
        read -n 1 -s -r -p "    Beliebige Taste..."
        return
    fi
    echo -e "${GREEN}    SHA256 OK ✓${RESET}"

    echo -e "${WHITE}    3/3 Schreibe auf ${BOOT_DEV}...${RESET}"
    echo -e "${RED}    NICHT AUSSCHALTEN!${RESET}"
    for mp in $(lsblk -nlo NAME "$BOOT_DEV" 2>/dev/null); do
        umount "/dev/$mp" 2>/dev/null
    done
    umount /run/archiso/bootmnt 2>/dev/null
    sleep 1
    dd if=/tmp/flowbit-update.iso of="$BOOT_DEV" bs=4M conv=fsync status=progress 2>&1
    sync
    rm -f /tmp/flowbit-update.iso

    echo ""
    echo -e "${GREEN}    ✓ Update auf v${LATEST_VER} erfolgreich!${RESET}"
    echo -e "${WHITE}    Neustart in 5s... (oder Taste drücken)${RESET}"
    read -t 5 -n 1 -s -r
    reboot -f
}

start_gui() {
    echo -e "${WHITE}    Starte Web-UI...${RESET}"
    python3 /opt/kit/webui/server.py &>/dev/null &
    sleep 1
    if startx 2>/tmp/startx.log; then
        true
    else
        echo -e "${RED}    X11 fehlgeschlagen.${RESET}"
        IP=$(get_ip)
        [ -n "$IP" ] && echo -e "${DIM}    Web-UI: http://${IP}:8080${RESET}"
        read -n 1 -s -r -p "    Beliebige Taste..."
    fi
}

# ========== MAIN MENU ==========
while true; do
    clear
    IP=$(get_ip)
    VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null | head -c 20)
    MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null | head -c 25)
    SERIAL=$(cat /sys/class/dmi/id/product_serial 2>/dev/null | head -c 20)

    echo ""
    echo -e "${TEAL}    ┌─────────────────────────────────────────────────────┐${RESET}"
    echo -e "${TEAL}    │${RESET}  ${BOLD}flowbit OS${RESET}  ${DIM}v${CURRENT_VER}${RESET}                                ${TEAL}│${RESET}"
    echo -e "${TEAL}    └─────────────────────────────────────────────────────┘${RESET}"
    echo ""
    echo -e "${DIM}    ${VENDOR} ${MODEL} | SN: ${SERIAL}${RESET}"
    if [ -n "$IP" ]; then
        echo -e "${TEAL}    IP: ${IP}${RESET}"
    else
        echo -e "${YELLOW}    IP: kein Netzwerk${RESET}"
    fi
    echo ""

    if [ "$UPDATE_AVAILABLE" = "1" ]; then
        echo -e "${GREEN}    ● Update: v${CURRENT_VER} → v${LATEST_VER}${RESET}"
        echo -e "${DIM}      ${NOTES}${RESET}"
        echo ""
    fi

    echo -e "${DIM}    ─────────────────────────────────────────────────────${RESET}"
    echo ""
    echo -e "${TEAL}    [1]${WHITE}  Web-UI starten          ${DIM}— Grafische Oberfläche${RESET}"
    echo -e "${TEAL}    [2]${WHITE}  CLI-Menü                ${DIM}— Terminal-Menü${RESET}"
    echo -e "${TEAL}    [3]${WHITE}  Shell                   ${DIM}— Bash${RESET}"
    echo ""
    if [ "$UPDATE_AVAILABLE" = "1" ]; then
        echo -e "${GREEN}    [u]${WHITE}  Update installieren     ${DIM}— v${LATEST_VER}${RESET}"
    else
        echo -e "${TEAL}    [u]${WHITE}  Nach Updates suchen${RESET}"
    fi
    echo -e "${TEAL}    [i]${WHITE}  System-Info${RESET}"
    echo -e "${TEAL}    [r]${WHITE}  Neustart${RESET}"
    echo -e "${TEAL}    [x]${WHITE}  Herunterfahren${RESET}"
    echo ""
    echo -e "${DIM}    ─────────────────────────────────────────────────────${RESET}"
    echo ""
    echo -ne "${WHITE}    Auswahl: ${TEAL}"
    read -n 1 choice
    echo -e "${RESET}"

    case "$choice" in
        1) start_gui ;;
        2) exec /opt/kit/kit.sh ;;
        3) echo -e "\n${DIM}    'exit' → zurück${RESET}\n"; bash ;;
        u|U)
            if [ "$UPDATE_AVAILABLE" = "1" ]; then
                do_update
            else
                echo ""
                check_update
            fi
            ;;
        i|I)
            echo ""
            CPU=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
            MEM=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')
            echo -e "${TEAL}    ── Hardware ────────────────────────────────${RESET}"
            echo -e "${WHITE}    Hersteller:  ${DIM}${VENDOR}${RESET}"
            echo -e "${WHITE}    Modell:      ${DIM}${MODEL}${RESET}"
            echo -e "${WHITE}    Seriennr.:   ${DIM}${SERIAL}${RESET}"
            echo -e "${WHITE}    CPU:         ${DIM}${CPU}${RESET}"
            echo -e "${WHITE}    RAM:         ${DIM}${MEM}${RESET}"
            echo -e "${WHITE}    Kernel:      ${DIM}$(uname -r)${RESET}"
            echo ""
            echo -e "${TEAL}    ── Datenträger ────────────────────────────${RESET}"
            lsblk -d -o NAME,SIZE,MODEL,TRAN 2>/dev/null | while IFS= read -r l; do echo -e "${DIM}    $l${RESET}"; done
            echo ""
            echo -e "${TEAL}    ── Netzwerk ────────────────────────────────${RESET}"
            ip -br addr 2>/dev/null | while IFS= read -r l; do echo -e "${DIM}    $l${RESET}"; done
            echo ""
            read -n 1 -s -r -p "    Beliebige Taste..."
            ;;
        r|R) echo -e "\n${YELLOW}    Neustart...${RESET}"; sleep 1; reboot ;;
        x|X) echo -e "\n${YELLOW}    Herunterfahren...${RESET}"; sleep 1; poweroff ;;
        *) ;;
    esac
done
