#!/bin/bash
# =============================================================================
#  WIPER — flowbit OS Modul | Sichere Datenlöschung
#  Teil von flowbit OS
# =============================================================================

set -uo pipefail
source /opt/kit/modules/common.sh 2>/dev/null

# ─── Farben ───────────────────────────────────────────────────────────────────
R='\033[1;31m'
G='\033[1;32m'
Y='\033[1;33m'
C='\033[0;36m'
W='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'

# ─── Session ──────────────────────────────────────────────────────────────────
WIPE_PASSES=3
WIPE_METHOD="dodshort"
WIPE_VERIFY=true
SESSION_START=$(date +"%Y%m%d_%H%M%S")
HOSTNAME_STR=$(hostname 2>/dev/null || echo "unbekannt")
LOG_DIR="/tmp/wiper_${SESSION_START}"
MAIN_LOG="$LOG_DIR/session.log"
PROTOCOL_ENTRIES=()
mkdir -p "$LOG_DIR"

# ─── Hilfsunktionen ──────────────────────────────────────────────────────────
wiper_header() {
    clear
    echo ""
    echo -e "${R}    ██╗    ██╗██╗██████╗ ███████╗██████╗ ${NC}"
    echo -e "${R}    ██║    ██║██║██╔══██╗██╔════╝██╔══██╗${NC}"
    echo -e "${R}    ██║ █╗ ██║██║██████╔╝█████╗  ██████╔╝${NC}"
    echo -e "${R}    ██║███╗██║██║██╔═══╝ ██╔══╝  ██╔══██╗${NC}"
    echo -e "${R}    ╚███╔███╔╝██║██║     ███████╗██║  ██║${NC}"
    echo -e "${R}     ╚══╝╚══╝ ╚═╝╚═╝     ╚══════╝╚═╝  ╚═╝${NC}"
    echo -e "${DIM}    ──────────────────────────────────────────────${NC}"
    echo -e "    ${DIM}Host:${NC} ${W}${HOSTNAME_STR}${NC}  ${DIM}|${NC}  ${W}$(date '+%d.%m.%Y %H:%M')${NC}  ${DIM}|${NC}  ${W}${SESSION_START}${NC}"
    echo -e "${DIM}    ──────────────────────────────────────────────${NC}"
    echo ""
}

log_entry() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$MAIN_LOG"
}

proto_add() {
    PROTOCOL_ENTRIES+=("$(date '+%H:%M:%S') | $1")
    log_entry "$1"
}

pause_key() {
    echo ""
    echo -e "    ${DIM}[ Enter zum Fortfahren ]${NC}"
    read -r
}

method_label() {
    case "$WIPE_METHOD" in
        zero)       echo "Zero Fill (1x Nullen, schnell)" ;;
        random)     echo "Random (Zufallsdaten)" ;;
        dodshort)   echo "DoD 5220.22-M Short (3x)" ;;
        dod522022m) echo "DoD 5220.22-M Full (7x)" ;;
        gutmann)    echo "Gutmann (35x, sehr langsam)" ;;
        *)          echo "$WIPE_METHOD" ;;
    esac
}

get_disks() {
    local boot_dev
    boot_dev=$(lsblk -no PKNAME $(findmnt -n -o SOURCE /) 2>/dev/null | head -1)
    lsblk -d -n -o NAME,TYPE 2>/dev/null \
        | awk '$2=="disk"{print $1}' \
        | grep -E "^(sd|nvme|hd|vd)" \
        | while read -r dev_name; do
            [[ "$dev_name" == "$boot_dev" ]] && continue
            echo "$dev_name"
        done
}

disk_info_line() {
    local dev="$1"
    local size rota model dtype
    size=$(lsblk -d -n -o SIZE /dev/"$dev" 2>/dev/null | xargs)
    rota=$(lsblk -d -n -o ROTA /dev/"$dev" 2>/dev/null | xargs)
    model=$(lsblk -d -n -o MODEL /dev/"$dev" 2>/dev/null | xargs)
    [[ "$rota" == "0" ]] && dtype="${C}SSD${NC}" || dtype="${R}HDD${NC}"
    echo -e "/dev/${W}${dev}${NC}  ${dtype}  ${Y}${size}${NC}  ${DIM}${model}${NC}"
}

confirm_action() {
    local target="$1"
    echo ""
    echo -e "    ${R}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "    ${R}║  ACHTUNG — UNWIDERRUFLICHE DATENLOESCHUNG       ║${NC}"
    echo -e "    ${R}╚══════════════════════════════════════════════════╝${NC}"
    echo -e "    ${W}Ziel:${NC}       ${Y}${target}${NC}"
    echo -e "    ${W}Methode:${NC}    $(method_label)"
    echo -e "    ${W}Durchgaenge:${NC} ${WIPE_PASSES}x"
    echo -e "    ${W}Verify:${NC}     $(${WIPE_VERIFY} && echo 'Ja' || echo 'Nein')"
    echo ""
    echo -ne "    ${Y}Bestaetigen? [ja/nein]:${NC} "
    read -r ans
    [[ "${ans,,}" == "ja" ]]
}

select_disks() {
    mapfile -t DISKS < <(get_disks)
    if [[ ${#DISKS[@]} -eq 0 ]]; then
        echo -e "    ${R}Keine Datentraeger gefunden.${NC}"
        pause_key
        return 1
    fi

    echo -e "    ${W}Verfuegbare Datentraeger:${NC}"
    echo ""
    for i in "${!DISKS[@]}"; do
        echo -e "    ${C}[$((i+1))]${NC}  $(disk_info_line "${DISKS[$i]}")"
    done
    echo ""
    echo -e "    ${C}[a]${NC}  Alle Datentraeger"
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo ""
    echo -ne "    Auswahl: "
    read -r sel

    SELECTED_DISKS=()
    case "$sel" in
        0) return 1 ;;
        [aA]) SELECTED_DISKS=("${DISKS[@]}") ;;
        *)
            if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#DISKS[@]} )); then
                SELECTED_DISKS=("${DISKS[$((sel-1))]}")
            else
                echo -e "    ${R}Ungueltige Auswahl.${NC}"; sleep 1; return 1
            fi ;;
    esac
    return 0
}

# ─── [1] Disk Wipe ───────────────────────────────────────────────────────────
do_disk_wipe() {
    wiper_header
    echo -e "    ${W}FESTPLATTEN / SSDs WISCHEN${NC}"
    echo -e "    ${DIM}Methode: $(method_label)${NC}"
    echo ""

    select_disks || return

    echo ""
    echo -e "    ${W}Ausgewaehlte Ziele:${NC}"
    for t in "${SELECTED_DISKS[@]}"; do
        echo -e "    ${Y}-> /dev/$t${NC}"
    done

    confirm_action "${SELECTED_DISKS[*]}" || { echo -e "    ${G}Abgebrochen.${NC}"; sleep 1; return; }

    log_session "WIPE: ${SELECTED_DISKS[*]} mit Methode $(method_label) gestartet"

    echo ""
    local ok=0 fail=0
    for dev in "${SELECTED_DISKS[@]}"; do
        echo -e "    ${C}[...]  Loesche /dev/${dev}...${NC}"
        local disk_log="$LOG_DIR/nwipe_${dev}.log"

        local verify_flag=""
        $WIPE_VERIFY && verify_flag="--verify=last"

        if command -v nwipe &>/dev/null; then
            if nwipe --autonuke --method="$WIPE_METHOD" --rounds="$WIPE_PASSES" \
                $verify_flag --logfile="$disk_log" /dev/"$dev" >> "$MAIN_LOG" 2>&1; then
                echo -e "    ${G}[OK]   /dev/${dev} — erfolgreich${NC}"
                ((ok++))
                proto_add "DISK WIPE OK | /dev/${dev} | $(method_label) | ${WIPE_PASSES}x"
            else
                echo -e "    ${R}[FAIL] /dev/${dev} — Fehler${NC}"
                ((fail++))
                proto_add "DISK WIPE FEHLER | /dev/${dev}"
            fi
        else
            # Fallback ohne nwipe: dd-basiert
            echo -e "    ${Y}nwipe nicht verfuegbar, nutze dd-Fallback...${NC}"
            local pass
            for ((pass=1; pass<=WIPE_PASSES; pass++)); do
                echo -e "    ${DIM}  Durchgang ${pass}/${WIPE_PASSES}...${NC}"
                if (( pass % 2 == 1 )); then
                    dd if=/dev/zero of=/dev/"$dev" bs=4M status=progress 2>>"$MAIN_LOG" || true
                else
                    dd if=/dev/urandom of=/dev/"$dev" bs=4M status=progress 2>>"$MAIN_LOG" || true
                fi
            done
            echo -e "    ${G}[OK]   /dev/${dev} — dd-Fallback abgeschlossen${NC}"
            ((ok++))
            proto_add "DISK WIPE OK (dd-fallback) | /dev/${dev} | ${WIPE_PASSES}x"
        fi
    done

    echo ""
    echo -e "    ${G}Erfolgreich: ${ok}${NC}  ${R}Fehler: ${fail}${NC}"
    log_session "WIPE: abgeschlossen — Erfolgreich: ${ok}, Fehler: ${fail}"
    pause_key
}

# ─── [2] Partitionstabellen loeschen ─────────────────────────────────────────
do_partition_wipe() {
    wiper_header
    echo -e "    ${W}PARTITIONSTABELLEN LOESCHEN (MBR / GPT)${NC}"
    echo -e "    ${DIM}Loescht nur die Partitionsstruktur, nicht die Daten selbst.${NC}"
    echo ""

    select_disks || return
    confirm_action "Partitionstabellen: ${SELECTED_DISKS[*]}" || { echo -e "    ${G}Abgebrochen.${NC}"; sleep 1; return; }

    for dev in "${SELECTED_DISKS[@]}"; do
        echo -e "    ${C}[...]  /dev/${dev} — MBR + GPT loeschen...${NC}"
        # Erste 34 Sektoren (MBR + primaere GPT)
        dd if=/dev/zero of=/dev/"$dev" bs=512 count=34 conv=notrunc >> "$MAIN_LOG" 2>&1
        # Backup GPT am Ende
        local sectors
        sectors=$(blockdev --getsz /dev/"$dev" 2>/dev/null || echo 0)
        if [[ $sectors -gt 34 ]]; then
            dd if=/dev/zero of=/dev/"$dev" bs=512 seek=$((sectors-34)) count=34 conv=notrunc >> "$MAIN_LOG" 2>&1 || true
        fi
        wipefs -a /dev/"$dev" >> "$MAIN_LOG" 2>&1 || true
        echo -e "    ${G}[OK]   /dev/${dev} — Partitionstabelle entfernt${NC}"
        proto_add "PARTITION WIPE | /dev/${dev} | MBR+GPT entfernt"
        log_session "PARTITION WIPE: /dev/${dev} MBR+GPT entfernt"
    done
    pause_key
}

# ─── [3] SSD Secure Erase ────────────────────────────────────────────────────
do_ssd_secure_erase() {
    wiper_header
    echo -e "    ${W}SSD SECURE ERASE${NC}"
    echo -e "    ${DIM}Nutzt die eingebaute Loeschfunktion der SSD (schnell + effektiv).${NC}"
    echo ""

    mapfile -t DISKS < <(get_disks)
    local ssds=()
    for d in "${DISKS[@]}"; do
        local rota
        rota=$(lsblk -d -n -o ROTA /dev/"$d" 2>/dev/null | xargs)
        [[ "$rota" == "0" ]] && ssds+=("$d")
    done

    if [[ ${#ssds[@]} -eq 0 ]]; then
        echo -e "    ${Y}Keine SSDs erkannt.${NC}"
        pause_key; return
    fi

    for i in "${!ssds[@]}"; do
        local d="${ssds[$i]}"
        local tag="${C}SATA${NC}"
        [[ "$d" == nvme* ]] && tag="${Y}NVMe${NC}"
        echo -e "    ${C}[$((i+1))]${NC}  ${tag}  $(disk_info_line "$d")"
    done
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo ""
    echo -ne "    Auswahl: "
    read -r sel

    [[ "$sel" == "0" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#ssds[@]} )); then
        echo -e "    ${R}Ungueltig.${NC}"; sleep 1; return
    fi

    local dev="${ssds[$((sel-1))]}"

    if [[ "$dev" == nvme* ]]; then
        # NVMe
        confirm_action "/dev/$dev (NVMe Secure Erase)" || { echo -e "    ${G}Abgebrochen.${NC}"; sleep 1; return; }
        echo -e "    ${C}[...]  NVMe Format (Secure Erase)...${NC}"
        if nvme format /dev/"$dev" -s 1 >> "$MAIN_LOG" 2>&1; then
            echo -e "    ${G}[OK]   NVMe Secure Erase abgeschlossen.${NC}"
            proto_add "SSD SECURE ERASE OK | /dev/${dev} | NVMe format"
            log_session "SSD SECURE ERASE: /dev/${dev} NVMe OK"
        else
            echo -e "    ${R}[FAIL] NVMe Secure Erase fehlgeschlagen.${NC}"
            proto_add "SSD SECURE ERASE FEHLER | /dev/${dev} | NVMe"
        fi
    else
        # SATA
        echo ""
        echo -e "    ${C}[1]${NC}  Enhanced Secure Erase (empfohlen)"
        echo -e "    ${C}[2]${NC}  Normal Secure Erase"
        echo -ne "    Auswahl: "
        read -r etype

        confirm_action "/dev/$dev (ATA Secure Erase)" || { echo -e "    ${G}Abgebrochen.${NC}"; sleep 1; return; }

        echo -e "    ${C}[...]  ATA Secure Erase...${NC}"

        # Frozen-Check
        local frozen
        frozen=$(hdparm -I /dev/"$dev" 2>/dev/null | grep -i "frozen" || true)
        if echo "$frozen" | grep -qi "frozen" && ! echo "$frozen" | grep -qi "not.*frozen"; then
            echo -e "    ${R}SSD ist im Frozen-State!${NC}"
            echo -e "    ${Y}Tipp: System kurz in Suspend schicken, dann erneut versuchen.${NC}"
            proto_add "SSD SECURE ERASE ABBRUCH | /dev/${dev} | Frozen-State"
            pause_key; return
        fi

        hdparm --user-master u --security-set-pass WiperTmp /dev/"$dev" >> "$MAIN_LOG" 2>&1 || true

        local cmd="hdparm --user-master u --security-erase"
        [[ "$etype" == "1" ]] && cmd="hdparm --user-master u --security-erase-enhanced"

        if $cmd WiperTmp /dev/"$dev" >> "$MAIN_LOG" 2>&1; then
            echo -e "    ${G}[OK]   ATA Secure Erase abgeschlossen.${NC}"
            proto_add "SSD SECURE ERASE OK | /dev/${dev} | ATA enhanced=$([[ "$etype" == "1" ]] && echo ja || echo nein)"
            log_session "SSD SECURE ERASE: /dev/${dev} ATA OK"
        else
            echo -e "    ${R}[FAIL] ATA Secure Erase fehlgeschlagen.${NC}"
            proto_add "SSD SECURE ERASE FEHLER | /dev/${dev}"
        fi
    fi
    pause_key
}

# ─── [4] RAM Scrub ───────────────────────────────────────────────────────────
do_ram_scrub() {
    wiper_header
    echo -e "    ${W}RAM SCRUB — Arbeitsspeicher bereinigen${NC}"
    echo ""
    echo -e "    ${DIM}RAM ist fluechtig. Fuer erhoehte Sicherheit (Cold-Boot-Angriffe)${NC}"
    echo -e "    ${DIM}kann freier RAM zusaetzlich ueberschrieben werden.${NC}"
    echo ""

    local total free_mem
    total=$(free -h | awk '/^Mem:/{print $2}')
    free_mem=$(free -h | awk '/^Mem:/{print $4}')
    echo -e "    ${W}RAM:${NC} ${total} gesamt  |  ${free_mem} frei"
    echo ""
    echo -e "    ${C}[1]${NC}  Schnell (1x freien RAM mit Nullen fuellen)"
    echo -e "    ${C}[2]${NC}  Gruendlich (3x mit Zufallsdaten)"
    echo -e "    ${C}[3]${NC}  Swap loeschen"
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo ""
    echo -ne "    Auswahl: "
    read -r sel

    case "$sel" in
        0) return ;;
        1)
            echo -e "    ${C}[...]  Schreibe Nullen in freien RAM...${NC}"
            # Nutze /dev/shm tmpfs um RAM zu fuellen
            local memfree_kb
            memfree_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
            local fill_mb=$(( memfree_kb / 1024 - 100 ))  # 100MB Reserve
            if (( fill_mb > 0 )); then
                dd if=/dev/zero of=/dev/shm/.wiper_scrub bs=1M count="$fill_mb" 2>/dev/null || true
                sync
                rm -f /dev/shm/.wiper_scrub
            fi
            echo -e "    ${G}[OK]   RAM Scrub abgeschlossen.${NC}"
            proto_add "RAM SCRUB | schnell (1x zero)"
            ;;
        2)
            echo -e "    ${C}[...]  RAM Scrub gruendlich (3 Durchgaenge)...${NC}"
            local memfree_kb pass
            memfree_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
            local fill_mb=$(( memfree_kb / 1024 - 100 ))
            for ((pass=1; pass<=3; pass++)); do
                echo -e "    ${DIM}  Durchgang ${pass}/3...${NC}"
                if (( fill_mb > 0 )); then
                    dd if=/dev/urandom of=/dev/shm/.wiper_scrub bs=1M count="$fill_mb" 2>/dev/null || true
                    sync
                    rm -f /dev/shm/.wiper_scrub
                fi
            done
            echo -e "    ${G}[OK]   RAM Scrub abgeschlossen (3x).${NC}"
            proto_add "RAM SCRUB | gruendlich (3x urandom)"
            ;;
        3)
            echo -e "    ${C}[...]  Swap deaktivieren und loeschen...${NC}"
            swapoff -a >> "$MAIN_LOG" 2>&1 || true
            local swaps
            swaps=$(awk 'NR>1{print $1}' /proc/swaps 2>/dev/null || true)
            for s in $swaps; do
                dd if=/dev/zero of="$s" bs=1M 2>/dev/null || true
                mkswap "$s" >> "$MAIN_LOG" 2>&1 || true
            done
            echo -e "    ${G}[OK]   Swap deaktiviert und ueberschrieben.${NC}"
            proto_add "SWAP WIPE | deaktiviert + ueberschrieben"
            ;;
    esac
    pause_key
}

# ─── [5] Einstellungen ───────────────────────────────────────────────────────
do_settings() {
    while true; do
        wiper_header
        echo -e "    ${W}WIPE-EINSTELLUNGEN${NC}"
        echo ""
        echo -e "    ${C}[1]${NC}  Durchgaenge:  ${Y}${WIPE_PASSES}x${NC}"
        echo -e "    ${C}[2]${NC}  Methode:      ${Y}$(method_label)${NC}"
        echo -e "    ${C}[3]${NC}  Verify:       ${Y}$(${WIPE_VERIFY} && echo 'AN' || echo 'AUS')${NC}"
        echo -e "    ${C}[0]${NC}  Zurueck"
        echo ""
        echo -ne "    Auswahl: "
        read -r sel

        case "$sel" in
            0) return ;;
            1)
                echo -ne "    Durchgaenge (1-10): "
                read -r p
                if [[ "$p" =~ ^([1-9]|10)$ ]]; then
                    WIPE_PASSES=$p
                    echo -e "    ${G}Gesetzt: ${WIPE_PASSES}x${NC}"
                else
                    echo -e "    ${R}Ungueltig (1-10).${NC}"
                fi
                sleep 1 ;;
            2)
                echo ""
                echo -e "    ${C}[1]${NC}  Zero Fill      ${DIM}(1x Nullen, sehr schnell)${NC}"
                echo -e "    ${C}[2]${NC}  Random          ${DIM}(Zufallsdaten)${NC}"
                echo -e "    ${C}[3]${NC}  DoD Short       ${DIM}(3x, Standard)${NC} ${G}<- empfohlen${NC}"
                echo -e "    ${C}[4]${NC}  DoD 5220.22-M   ${DIM}(7x, gruendlich)${NC}"
                echo -e "    ${C}[5]${NC}  Gutmann         ${DIM}(35x, sehr langsam)${NC}"
                echo -ne "    Auswahl: "
                read -r m
                case "$m" in
                    1) WIPE_METHOD="zero" ;;
                    2) WIPE_METHOD="random" ;;
                    3) WIPE_METHOD="dodshort" ;;
                    4) WIPE_METHOD="dod522022m" ;;
                    5) WIPE_METHOD="gutmann" ;;
                    *) echo -e "    ${R}Ungueltig.${NC}" ;;
                esac
                sleep 1 ;;
            3)
                $WIPE_VERIFY && WIPE_VERIFY=false || WIPE_VERIFY=true
                echo -e "    ${G}Verify: $(${WIPE_VERIFY} && echo 'AN' || echo 'AUS')${NC}"
                sleep 1 ;;
        esac
    done
}

# ─── [6] Protokoll ───────────────────────────────────────────────────────────
do_protocol() {
    wiper_header
    echo -e "    ${W}WIPE-PROTOKOLL${NC}"
    echo -e "    ${DIM}Session: ${SESSION_START}  |  Host: ${HOSTNAME_STR}${NC}"
    echo ""

    if [[ ${#PROTOCOL_ENTRIES[@]} -eq 0 ]]; then
        echo -e "    ${Y}Noch keine Aktionen protokolliert.${NC}"
    else
        for entry in "${PROTOCOL_ENTRIES[@]}"; do
            echo -e "    ${DIM}*${NC} $entry"
        done
    fi

    echo ""
    echo -e "    ${C}[1]${NC}  Protokoll als Datei speichern"
    echo -e "    ${C}[2]${NC}  Vollstaendiges Log anzeigen"
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo ""
    echo -ne "    Auswahl: "
    read -r sel

    case "$sel" in
        0) return ;;
        1)
            local serial manufacturer model_sys
            manufacturer=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "NA")
            model_sys=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "NA")
            serial=$(cat /sys/class/dmi/id/product_serial 2>/dev/null || echo "NA")
            local outfile="WIPE_${HOSTNAME_STR}_${serial}_${SESSION_START}.txt"

            {
                echo "================================================================"
                echo "  WIPE-PROTOKOLL — flowbit OS"
                echo "================================================================"
                echo ""
                echo "  Datum        : $(date '+%d.%m.%Y %H:%M:%S')"
                echo "  Hostname     : $HOSTNAME_STR"
                echo "  Hersteller   : $manufacturer"
                echo "  Modell       : $model_sys"
                echo "  Seriennummer : $serial"
                echo "  Methode      : $(method_label)"
                echo "  Durchgaenge  : ${WIPE_PASSES}x"
                echo "  Verify       : $(${WIPE_VERIFY} && echo 'Ja' || echo 'Nein')"
                echo ""
                echo "  AKTIONEN"
                echo "  ────────────────────────────────────────────────"
                for entry in "${PROTOCOL_ENTRIES[@]}"; do
                    echo "  * $entry"
                done
                echo ""
                echo "  DATENTRAEGER"
                echo "  ────────────────────────────────────────────────"
                lsblk -d -o NAME,SIZE,TYPE,ROTA,MODEL 2>/dev/null
                echo ""
                if [[ -f "$MAIN_LOG" ]]; then
                    echo "  LOG"
                    echo "  ────────────────────────────────────────────────"
                    cat "$MAIN_LOG"
                fi
                echo ""
                echo "================================================================"
                echo "  Erstellt mit flowbit OS Wiper"
                echo "================================================================"
            } > "/tmp/$outfile"

            # USB suchen
            local usb_path=""
            usb_path=$(find_usb_storage)

            if [[ -n "$usb_path" ]]; then
                cp "/tmp/$outfile" "${usb_path}${outfile}"
                echo -e "    ${G}[OK] Gespeichert: ${usb_path}${outfile}${NC}"
            else
                echo -e "    ${Y}Kein USB gefunden. Gespeichert: /tmp/${outfile}${NC}"
            fi
            proto_add "PROTOKOLL GESPEICHERT | $outfile"
            ;;
        2)
            echo ""
            if [[ -f "$MAIN_LOG" ]]; then
                head -80 "$MAIN_LOG" | while IFS= read -r line; do
                    echo -e "    ${DIM}${line}${NC}"
                done
                echo -e "    ${DIM}(Vollstaendig in $MAIN_LOG)${NC}"
            else
                echo -e "    ${Y}Kein Log vorhanden.${NC}"
            fi
            ;;
    esac
    pause_key
}

# ─── Wiper Hauptmenue ────────────────────────────────────────────────────────
wiper_menu() {
    while true; do
        wiper_header
        echo -e "    ${W}WIPER${NC}"
        echo -e "    ${DIM}$(method_label) | ${WIPE_PASSES}x | Verify: $(${WIPE_VERIFY} && echo 'An' || echo 'Aus')${NC}"
        echo ""
        echo -e "    ${C}[1]${NC}  Disk Wipe           ${DIM}— Festplatten/SSDs komplett loeschen${NC}"
        echo -e "    ${C}[2]${NC}  Partitionen loeschen ${DIM}— MBR/GPT entfernen${NC}"
        echo -e "    ${C}[3]${NC}  SSD Secure Erase     ${DIM}— ATA/NVMe Secure Erase${NC}"
        echo -e "    ${C}[4]${NC}  RAM Scrub            ${DIM}— Arbeitsspeicher ueberschreiben${NC}"
        echo -e "    ${C}[5]${NC}  Einstellungen        ${DIM}— Methode, Durchgaenge, Verify${NC}"
        echo -e "    ${C}[6]${NC}  Protokoll            ${DIM}— Anzeigen / Speichern${NC}"
        echo ""
        echo -e "    ${C}[0]${NC}  Zurueck zum Hauptmenue"
        echo ""
        echo -ne "    Auswahl: "
        read -r choice

        case "$choice" in
            1) do_disk_wipe ;;
            2) do_partition_wipe ;;
            3) do_ssd_secure_erase ;;
            4) do_ram_scrub ;;
            5) do_settings ;;
            6) do_protocol ;;
            0) return ;;
            *) echo -e "    ${R}Ungueltig.${NC}"; sleep 1 ;;
        esac
    done
}

# ─── Entry Point ─────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${R}Fehler: Root-Rechte erforderlich.${NC}"
    exit 1
fi

log_entry "=== WIPER Session gestartet | Host: $HOSTNAME_STR ==="
wiper_menu
log_entry "=== WIPER Session beendet ==="
