# flowbit OS Auto-Start
if [[ "$(tty)" == "/dev/tty1" ]]; then
    CYAN="\033[1;36m"
    WHITE="\033[0;37m"
    GREEN="\033[1;32m"
    YELLOW="\033[1;33m"
    RED="\033[1;31m"
    DIM="\033[2m"
    RESET="\033[0m"

    CURRENT_VER=$(cat /etc/flowbit-release 2>/dev/null || echo "0.0.0")

    echo ""
    echo -e "${CYAN}    flowbit OS${RESET} ${DIM}v${CURRENT_VER}${RESET}"
    echo ""

    # ---- AUTO-UPDATE CHECK ----
    echo -e "${DIM}    Prüfe auf Updates...${RESET}"
    MANIFEST=$(curl -sf --connect-timeout 3 --max-time 5 https://update.flowbit.ch/manifest.json 2>/dev/null)
    if [ -n "$MANIFEST" ]; then
        LATEST_VER=$(echo "$MANIFEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('latest',{}).get('version','0.0.0'))" 2>/dev/null)
        ISO_URL=$(echo "$MANIFEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('latest',{}).get('iso',{}).get('url',''))" 2>/dev/null)
        ISO_SHA=$(echo "$MANIFEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('latest',{}).get('iso',{}).get('sha256',''))" 2>/dev/null)
        NOTES=$(echo "$MANIFEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('latest',{}).get('release_notes',''))" 2>/dev/null)

        if [ -n "$LATEST_VER" ] && [ "$LATEST_VER" != "$CURRENT_VER" ] && [ -n "$ISO_URL" ]; then
            echo ""
            echo -e "${GREEN}    Update verfügbar: v${CURRENT_VER} → v${LATEST_VER}${RESET}"
            echo -e "${DIM}    ${NOTES}${RESET}"
            echo ""
            echo -e "${WHITE}    [u] Update jetzt installieren${RESET}"
            echo -e "${WHITE}    [s] Überspringen${RESET}"
            echo ""
            echo -ne "${WHITE}    Auswahl (auto-skip in 15s): ${RESET}"
            UPD_CHOICE=""
            read -t 15 -n 1 UPD_CHOICE
            echo ""

            if [ "$UPD_CHOICE" = "u" ] || [ "$UPD_CHOICE" = "U" ]; then
                # Find boot device
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

                if [ -n "$BOOT_DEV" ]; then
                    echo ""
                    echo -e "${YELLOW}    Boot-Device: ${BOOT_DEV}${RESET}"
                    echo -e "${WHITE}    Lade ISO herunter...${RESET}"
                    echo ""

                    curl -f -L --progress-bar -o /tmp/flowbit-update.iso "$ISO_URL"

                    if [ $? -eq 0 ] && [ -f /tmp/flowbit-update.iso ]; then
                        echo -e "${DIM}    Prüfe SHA256...${RESET}"
                        ACTUAL_SHA=$(sha256sum /tmp/flowbit-update.iso | awk '{print $1}')
                        if [ "$ACTUAL_SHA" = "$ISO_SHA" ] || [ -z "$ISO_SHA" ]; then
                            echo -e "${GREEN}    SHA256 OK${RESET}"
                            echo ""
                            echo -e "${YELLOW}    Schreibe auf ${BOOT_DEV}...${RESET}"

                            # Unmount everything
                            for mp in $(lsblk -nlo NAME "$BOOT_DEV" 2>/dev/null); do
                                umount "/dev/$mp" 2>/dev/null
                            done
                            umount /run/archiso/bootmnt 2>/dev/null

                            dd if=/tmp/flowbit-update.iso of="$BOOT_DEV" bs=4M status=progress oflag=sync 2>&1
                            sync
                            rm -f /tmp/flowbit-update.iso

                            echo ""
                            echo -e "${GREEN}    Update erfolgreich! Neustart in 3s...${RESET}"
                            sleep 3
                            reboot -f
                        else
                            echo -e "${RED}    SHA256 Fehler! Abgebrochen.${RESET}"
                            rm -f /tmp/flowbit-update.iso
                            sleep 5
                        fi
                    else
                        echo -e "${RED}    Download fehlgeschlagen!${RESET}"
                        sleep 3
                    fi
                else
                    echo -e "${RED}    Boot-Device nicht gefunden!${RESET}"
                    sleep 3
                fi
            else
                echo -e "${DIM}    Update übersprungen.${RESET}"
            fi
        else
            echo -e "${DIM}    System ist aktuell (v${CURRENT_VER}).${RESET}"
        fi
    else
        echo -e "${DIM}    Offline — Update-Check übersprungen.${RESET}"
    fi

    # ---- BOOT MENU ----
    echo ""
    echo -e "${WHITE}    [1] Web-UI starten (Grafisch)${RESET}"
    echo -e "${WHITE}    [2] CLI-Menü${RESET}"
    echo ""
    echo -e "${DIM}    Automatischer Start Web-UI in 5 Sekunden...${RESET}"
    echo ""

    choice=""
    read -t 5 -n 1 choice

    case "$choice" in
        2)
            /opt/kit/kit.sh
            ;;
        *)
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
                sleep 3
                /opt/kit/kit.sh
            fi
            ;;
    esac
fi
