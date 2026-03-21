#!/bin/bash
# flowbit OS Boot Menu v2

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
NETWORK_OK=""

# ---- Ensure network is running ----
ensure_network() {
    # Start NetworkManager if not running (handles both WiFi + Ethernet)
    if command -v nmcli &>/dev/null; then
        if ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
            systemctl start NetworkManager 2>/dev/null
        fi
    fi
    # Also ensure systemd-resolved for DNS
    if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl start systemd-resolved 2>/dev/null
    fi
}

# ---- Wait for actual internet connectivity ----
wait_for_network() {
    echo -ne "${DIM}    Netzwerk: "
    for i in $(seq 1 20); do
        # Test actual connectivity, not just route
        if curl -sf --connect-timeout 2 --max-time 3 https://update.flowbit.ch/manifest.json >/dev/null 2>&1; then
            echo -e "verbunden${RESET}"
            NETWORK_OK="1"
            return 0
        fi
        echo -n "."
        sleep 1
    done
    echo -e "offline${RESET}"
    NETWORK_OK=""
    return 1
}

# ---- Check for updates ----
check_update() {
    UPDATE_AVAILABLE=""
    if [ -z "$NETWORK_OK" ]; then
        return
    fi
    MANIFEST=$(curl -sf --connect-timeout 5 --max-time 10 https://update.flowbit.ch/manifest.json 2>/dev/null)
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

# ---- Flash update ----
do_update() {
    # Find boot device
    BOOT_PART=""

    # Method 1: archiso bootmnt (most reliable)
    BOOT_PART=$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null)

    # Method 2: archiso search UUID from kernel cmdline
    if [ -z "$BOOT_PART" ]; then
        AUUID=$(grep -o 'archisosearchuuid=[^ ]*' /proc/cmdline 2>/dev/null | cut -d= -f2)
        [ -n "$AUUID" ] && BOOT_PART=$(blkid -U "$AUUID" 2>/dev/null)
    fi

    # Method 3: any partition with FLOWBIT in label
    if [ -z "$BOOT_PART" ]; then
        BOOT_PART=$(blkid 2>/dev/null | grep -i "FLOWBIT" | head -1 | cut -d: -f1)
    fi

    # Method 4: first USB removable device
    if [ -z "$BOOT_PART" ]; then
        USB_DEV=$(lsblk -ndo NAME,TRAN,RM 2>/dev/null | awk '/usb/{print "/dev/"$1}' | head -1)
        [ -n "$USB_DEV" ] && BOOT_PART="$USB_DEV"
    fi

    # Method 5: cdrom/sr0 (VM)
    if [ -z "$BOOT_PART" ]; then
        [ -b /dev/sr0 ] && BOOT_PART="/dev/sr0"
    fi

    # Get parent disk
    BOOT_DEV=""
    if [ -n "$BOOT_PART" ]; then
        PARENT=$(lsblk -ndo PKNAME "$BOOT_PART" 2>/dev/null)
        if [ -n "$PARENT" ]; then
            BOOT_DEV="/dev/$PARENT"
        else
            BOOT_DEV="$BOOT_PART"
        fi
    fi

    if [ -z "$BOOT_DEV" ] || [ "$BOOT_DEV" = "/dev/" ]; then
        echo -e "\n${RED}    Kein Boot-Device gefunden!${RESET}"
        echo -e "${DIM}    Stelle sicher, dass ein USB-Stick eingesteckt ist.${RESET}"
        read -n 1 -s -r -p "    Beliebige Taste..."
        return
    fi

    # Confirm
    DEV_SIZE=$(lsblk -ndo SIZE "$BOOT_DEV" 2>/dev/null)
    DEV_MODEL=$(lsblk -ndo MODEL "$BOOT_DEV" 2>/dev/null)
    echo ""
    echo -e "${YELLOW}    ┌──────────────────────────────────────────────┐${RESET}"
    echo -e "${YELLOW}    │  Update: v${CURRENT_VER} → v${LATEST_VER}${RESET}"
    echo -e "${YELLOW}    │  Ziel:   ${BOOT_DEV} (${DEV_SIZE} ${DEV_MODEL})${RESET}"
    echo -e "${YELLOW}    │  ACHTUNG: Alle Daten auf dem Stick werden${RESET}"
    echo -e "${YELLOW}    │           überschrieben!${RESET}"
    echo -e "${YELLOW}    └──────────────────────────────────────────────┘${RESET}"
    echo ""
    echo -ne "${WHITE}    Fortfahren? [j/n]: ${TEAL}"
    read -n 1 CONFIRM
    echo -e "${RESET}"

    if [ "$CONFIRM" != "j" ] && [ "$CONFIRM" != "J" ]; then
        echo -e "${DIM}    Abgebrochen.${RESET}"
        sleep 1
        return
    fi

    # Download
    echo ""
    echo -e "${WHITE}    Schritt 1/3: Lade ISO herunter...${RESET}"
    echo ""
    curl -f -L --progress-bar -o /tmp/flowbit-update.iso "$ISO_URL"
    if [ $? -ne 0 ] || [ ! -f /tmp/flowbit-update.iso ]; then
        echo -e "\n${RED}    Download fehlgeschlagen!${RESET}"
        rm -f /tmp/flowbit-update.iso
        read -n 1 -s -r -p "    Beliebige Taste..."
        return
    fi

    # Verify
    echo ""
    echo -e "${WHITE}    Schritt 2/3: Prüfe Integrität...${RESET}"
    ACTUAL_SHA=$(sha256sum /tmp/flowbit-update.iso | awk '{print $1}')
    if [ -n "$ISO_SHA" ] && [ "$ACTUAL_SHA" != "$ISO_SHA" ]; then
        echo -e "${RED}    SHA256 stimmt nicht überein! Abgebrochen.${RESET}"
        echo -e "${DIM}    Erwartet: ${ISO_SHA:0:16}...${RESET}"
        echo -e "${DIM}    Erhalten: ${ACTUAL_SHA:0:16}...${RESET}"
        rm -f /tmp/flowbit-update.iso
        read -n 1 -s -r -p "    Beliebige Taste..."
        return
    fi
    echo -e "${GREEN}    SHA256 OK ✓${RESET}"

    # Flash
    echo ""
    echo -e "${WHITE}    Schritt 3/3: Schreibe auf ${BOOT_DEV}...${RESET}"
    echo -e "${RED}    NICHT AUSSCHALTEN!${RESET}"
    echo ""

    # Unmount everything on target device
    for mp in $(lsblk -nlo NAME "$BOOT_DEV" 2>/dev/null); do
        umount "/dev/$mp" 2>/dev/null
    done
    umount /run/archiso/bootmnt 2>/dev/null
    sleep 1

    # Flash with progress
    dd if=/tmp/flowbit-update.iso of="$BOOT_DEV" bs=4M conv=fsync status=progress 2>&1
    sync
    rm -f /tmp/flowbit-update.iso

    echo ""
    echo -e "${GREEN}    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${GREEN}    ✓ Update auf v${LATEST_VER} erfolgreich!${RESET}"
    echo -e "${GREEN}    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    echo -e "${WHITE}    System startet in 5 Sekunden neu...${RESET}"
    echo -e "${DIM}    (oder beliebige Taste drücken)${RESET}"
    read -t 5 -n 1 -s -r
    reboot -f
}

# ---- Start GUI ----
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
        IP=$(hostname -I 2>/dev/null | awk '{print $1}')
        [ -n "$IP" ] && echo -e "${DIM}    Web-UI: http://${IP}:8080${RESET}"
        echo ""
        read -n 1 -s -r -p "    Beliebige Taste..."
    fi
}

# ========== STARTUP ==========
clear
echo ""
echo -e "${TEAL}    flowbit OS${RESET} ${DIM}v${CURRENT_VER}${RESET}"
echo ""

# Ensure network services
ensure_network

# Wait for connectivity
wait_for_network

# Check for updates
if [ "$NETWORK_OK" = "1" ]; then
    echo -ne "${DIM}    Updates:  "
    check_update
    if [ "$UPDATE_AVAILABLE" = "1" ]; then
        echo -e "${GREEN}v${LATEST_VER} verfügbar!${RESET}"
    else
        echo -e "aktuell${RESET}"
    fi
fi

sleep 1

# ========== MAIN MENU ==========
while true; do
    clear
    echo ""
    echo -e "${TEAL}    ┌─────────────────────────────────────────────────────┐${RESET}"
    echo -e "${TEAL}    │${RESET}  ${BOLD}flowbit OS${RESET}  ${DIM}v${CURRENT_VER}${RESET}                                ${TEAL}│${RESET}"
    echo -e "${TEAL}    └─────────────────────────────────────────────────────┘${RESET}"
    echo ""

    # System info
    VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null | head -c 20)
    MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null | head -c 25)
    SERIAL=$(cat /sys/class/dmi/id/product_serial 2>/dev/null | head -c 20)
    echo -e "${DIM}    ${VENDOR} ${MODEL} | SN: ${SERIAL}${RESET}"
    echo ""

    # Status
    if [ "$UPDATE_AVAILABLE" = "1" ]; then
        echo -e "${GREEN}    ● Update verfügbar: v${CURRENT_VER} → v${LATEST_VER}${RESET}"
        echo -e "${DIM}      ${NOTES}${RESET}"
    elif [ "$NETWORK_OK" = "1" ]; then
        echo -e "${TEAL}    ● System ist aktuell${RESET}"
    else
        echo -e "${YELLOW}    ● Offline — kein Update-Check möglich${RESET}"
    fi
    echo ""
    echo -e "${DIM}    ─────────────────────────────────────────────────────${RESET}"
    echo ""

    # Menu
    echo -e "${TEAL}    [1]${WHITE}  Web-UI starten          ${DIM}— Grafische Oberfläche${RESET}"
    echo -e "${TEAL}    [2]${WHITE}  CLI-Menü                ${DIM}— Klassisches Terminal-Menü${RESET}"
    echo -e "${TEAL}    [3]${WHITE}  Shell                   ${DIM}— Direkt in die Bash${RESET}"
    echo ""
    if [ "$UPDATE_AVAILABLE" = "1" ]; then
        echo -e "${GREEN}    [u]${WHITE}  Update installieren     ${DIM}— v${LATEST_VER} herunterladen & flashen${RESET}"
    fi
    if [ -z "$NETWORK_OK" ]; then
        echo -e "${YELLOW}    [n]${WHITE}  Netzwerk neu prüfen     ${DIM}— Update-Check wiederholen${RESET}"
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
        1) start_gui ;;
        2) exec /opt/kit/kit.sh ;;
        3)
            echo -e "\n${DIM}    'exit' um zurückzukehren${RESET}\n"
            bash
            ;;
        u|U)
            [ "$UPDATE_AVAILABLE" = "1" ] && do_update
            ;;
        n|N)
            echo ""
            ensure_network
            wait_for_network
            check_update
            sleep 1
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
