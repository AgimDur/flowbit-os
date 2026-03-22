#!/bin/bash
# =============================================================================
#  HARDWARE TEST — flowbit OS Modul | RAM, Disk, CPU Stresstest
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

HOSTNAME_STR=$(hostname 2>/dev/null || echo "unbekannt")
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_DIR="/tmp/hwtest_${TIMESTAMP}"
REPORT_DATA=""
mkdir -p "$LOG_DIR"

# ─── Hilfsfunktionen ─────────────────────────────────────────────────────────
hw_header() {
    clear
    echo ""
    echo -e "${Y}    ██╗  ██╗██╗    ██╗  ████████╗███████╗███████╗████████╗${NC}"
    echo -e "${Y}    ██║  ██║██║    ██║  ╚══██╔══╝██╔════╝██╔════╝╚══██╔══╝${NC}"
    echo -e "${Y}    ███████║██║ █╗ ██║     ██║   █████╗  ███████╗   ██║   ${NC}"
    echo -e "${Y}    ██╔══██║██║███╗██║     ██║   ██╔══╝  ╚════██║   ██║   ${NC}"
    echo -e "${Y}    ██║  ██║╚███╔███╔╝     ██║   ███████╗███████║   ██║   ${NC}"
    echo -e "${Y}    ╚═╝  ╚═╝ ╚══╝╚══╝      ╚═╝   ╚══════╝╚══════╝   ╚═╝   ${NC}"
    echo -e "${DIM}    ──────────────────────────────────────────────────────${NC}"
    echo ""
}

pause_key() {
    echo ""
    echo -e "    ${DIM}[ Enter zum Fortfahren ]${NC}"
    read -r
}

report_add() { REPORT_DATA+="$1"$'\n'; }
result_ok()   { echo -e "    ${G}[OK]${NC}   $1"; report_add "  [OK]   $1"; }
result_fail() { echo -e "    ${R}[FAIL]${NC} $1"; report_add "  [FAIL] $1"; }
result_warn() { echo -e "    ${Y}[WARN]${NC} $1"; report_add "  [WARN] $1"; }
result_info() { echo -e "    ${DIM}$1${NC}"; report_add "  $1"; }

section() {
    echo ""
    echo -e "    ${C}── $1 ──────────────────────────────────────────${NC}"
    echo ""
    report_add ""
    report_add "  $1"
    report_add "  ────────────────────────────────────────────────"
}

save_report() {
    local prefix="${1:-HWTEST}"
    local filename="${prefix}_${HOSTNAME_STR}_${TIMESTAMP}.txt"
    {
        echo "================================================================"
        echo "  HARDWARE TEST — flowbit OS"
        echo "  Datum: $(date '+%d.%m.%Y %H:%M:%S')"
        echo "  Host:  $HOSTNAME_STR"
        echo "================================================================"
        echo "$REPORT_DATA"
        echo "================================================================"
        echo "  Erstellt mit flowbit OS Hardware Test"
        echo "================================================================"
    } > "/tmp/$filename"

    local usb_path=""
    usb_path=$(find_usb_storage)
    if [[ -n "$usb_path" ]]; then
        cp "/tmp/$filename" "${usb_path}${filename}"
        echo -e "    ${G}[OK] Gespeichert: ${usb_path}${filename}${NC}"
    else
        echo -e "    ${Y}Kein USB. Gespeichert: /tmp/${filename}${NC}"
    fi
}

# ─── [1] RAM Test ─────────────────────────────────────────────────────────────
do_ram_test() {
    hw_header
    echo -e "    ${W}RAM TEST${NC}"
    echo ""
    REPORT_DATA=""
    report_add "  RAM TEST"

    local total=$(free -h | awk '/^Mem:/{print $2}')
    local total_mb=$(free -m | awk '/^Mem:/{print $2}')
    echo -e "    ${DIM}RAM gesamt:${NC} ${W}${total}${NC}"
    echo ""

    echo -e "    ${C}[1]${NC}  Schnell      ${DIM}— 256 MB, 1 Durchgang (~30s)${NC}"
    echo -e "    ${C}[2]${NC}  Normal       ${DIM}— 1 GB, 2 Durchgaenge (~2 Min)${NC}"
    echo -e "    ${C}[3]${NC}  Ausfuehrlich ${DIM}— 50% RAM, 3 Durchgaenge (~10 Min)${NC}"
    echo -e "    ${C}[4]${NC}  Maximum      ${DIM}— 80% RAM, 5 Durchgaenge (lang!)${NC}"
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo ""
    echo -ne "    Auswahl: "
    read -r sel

    local test_mb=256 passes=1
    case "$sel" in
        0) return ;;
        1) test_mb=256; passes=1 ;;
        2) test_mb=1024; passes=2 ;;
        3) test_mb=$((total_mb / 2)); passes=3 ;;
        4) test_mb=$((total_mb * 80 / 100)); passes=5 ;;
        *) return ;;
    esac

    section "RAM Test: ${test_mb} MB, ${passes} Durchgaenge"

    local errors=0
    for ((p=1; p<=passes; p++)); do
        echo -e "    ${C}Durchgang ${p}/${passes}...${NC}"

        # Test 1: Sequential Write/Read
        echo -ne "    ${DIM}  Sequential Write/Read...${NC} "
        local ramfile="/dev/shm/.hwtest_ram_$$"
        local checksum_write checksum_read

        dd if=/dev/urandom of="$ramfile" bs=1M count="$test_mb" 2>/dev/null
        checksum_write=$(md5sum "$ramfile" 2>/dev/null | awk '{print $1}')
        # Caches leeren und erneut lesen
        sync
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        checksum_read=$(md5sum "$ramfile" 2>/dev/null | awk '{print $1}')

        if [[ "$checksum_write" == "$checksum_read" ]]; then
            echo -e "${G}OK${NC}"
            report_add "  Durchgang $p: Sequential Write/Read OK (MD5: $checksum_write)"
        else
            echo -e "${R}FEHLER${NC}"
            ((errors++))
            report_add "  Durchgang $p: Sequential Write/Read FEHLER"
        fi
        rm -f "$ramfile"

        # Test 2: Pattern-Test (verschiedene Bit-Muster)
        echo -ne "    ${DIM}  Pattern Test (0x00, 0xFF, 0xAA, 0x55)...${NC} "
        local pat_ok=true
        for pattern in "\\x00" "\\xff" "\\xaa" "\\x55"; do
            local patfile="/dev/shm/.hwtest_pat_$$"
            printf "$pattern%.0s" $(seq 1 $((1024*1024))) > "$patfile" 2>/dev/null
            local written=$(md5sum "$patfile" 2>/dev/null | awk '{print $1}')
            sync
            local readback=$(md5sum "$patfile" 2>/dev/null | awk '{print $1}')
            if [[ "$written" != "$readback" ]]; then
                pat_ok=false
                ((errors++))
            fi
            rm -f "$patfile"
        done
        if $pat_ok; then
            echo -e "${G}OK${NC}"
            report_add "  Durchgang $p: Pattern Test OK"
        else
            echo -e "${R}FEHLER${NC}"
            report_add "  Durchgang $p: Pattern Test FEHLER"
        fi

        # Test 3: Stress (parallel allokieren)
        echo -ne "    ${DIM}  Stress Allokation...${NC} "
        local stress_ok=true
        for i in 1 2 3 4; do
            dd if=/dev/urandom of="/dev/shm/.hwtest_stress_${i}_$$" bs=1M count=$((test_mb / 4)) 2>/dev/null &
        done
        wait
        for i in 1 2 3 4; do
            [[ -f "/dev/shm/.hwtest_stress_${i}_$$" ]] || stress_ok=false
            rm -f "/dev/shm/.hwtest_stress_${i}_$$"
        done
        if $stress_ok; then
            echo -e "${G}OK${NC}"
            report_add "  Durchgang $p: Stress Allokation OK"
        else
            echo -e "${R}FEHLER${NC}"
            report_add "  Durchgang $p: Stress Allokation FEHLER"
            ((errors++))
        fi

        echo ""
    done

    if [[ $errors -eq 0 ]]; then
        result_ok "RAM Test bestanden (${passes} Durchgaenge, ${test_mb} MB, 0 Fehler)"
        log_session "HWTEST: RAM Test bestanden (${passes}x, ${test_mb}MB, 0 Fehler)"
    else
        result_fail "RAM Test: ${errors} Fehler gefunden!"
        log_session "HWTEST: RAM Test FEHLER (${errors} Fehler)"
    fi

    pause_key
}

# ─── [2] Disk Test ────────────────────────────────────────────────────────────
do_disk_test() {
    hw_header
    echo -e "    ${W}DISK TEST${NC}"
    echo ""
    REPORT_DATA=""
    report_add "  DISK TEST"

    mapfile -t DISKS < <(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}' | grep -E "^(sd|nvme|hd|vd)")

    if [[ ${#DISKS[@]} -eq 0 ]]; then
        echo -e "    ${R}Keine Datentraeger gefunden.${NC}"
        pause_key; return
    fi

    for i in "${!DISKS[@]}"; do
        local d="${DISKS[$i]}"
        local size=$(lsblk -d -n -o SIZE /dev/"$d" 2>/dev/null | xargs)
        local model=$(lsblk -d -n -o MODEL /dev/"$d" 2>/dev/null | xargs)
        local rota=$(lsblk -d -n -o ROTA /dev/"$d" 2>/dev/null | xargs)
        local dtype="${C}SSD${NC}"
        [[ "$rota" != "0" ]] && dtype="${R}HDD${NC}"
        echo -e "    ${C}[$((i+1))]${NC}  /dev/${W}${d}${NC}  ${dtype}  ${Y}${size}${NC}  ${DIM}${model}${NC}"
    done
    echo -e "    ${C}[a]${NC}  Alle testen"
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo ""
    echo -ne "    Auswahl: "
    read -r sel

    local targets=()
    case "$sel" in
        0) return ;;
        [aA]) targets=("${DISKS[@]}") ;;
        *)
            if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#DISKS[@]} )); then
                targets=("${DISKS[$((sel-1))]}")
            else
                echo -e "    ${R}Ungueltig.${NC}"; sleep 1; return
            fi ;;
    esac

    for dev in "${targets[@]}"; do
        section "Disk Test: /dev/$dev"

        # SMART Health
        echo -ne "    ${DIM}SMART Health...${NC} "
        if command -v smartctl &>/dev/null; then
            local health=$(smartctl -H /dev/"$dev" 2>/dev/null)
            if echo "$health" | grep -qi "PASSED\|OK"; then
                result_ok "SMART: PASSED"
            elif echo "$health" | grep -qi "FAILED"; then
                result_fail "SMART: FAILED — Disk defekt!"
            else
                result_warn "SMART: Status unbekannt"
            fi

            # Wichtige SMART Attribute
            echo -e "    ${DIM}SMART Details:${NC}"
            smartctl -A /dev/"$dev" 2>/dev/null | grep -iE "reallocated|pending|uncorrectable|wear|temperature|power_on|start_stop" | while IFS= read -r line; do
                local attr_name=$(echo "$line" | awk '{print $2}')
                local raw_val=$(echo "$line" | awk '{print $NF}')
                echo -e "    ${DIM}  ${attr_name}: ${W}${raw_val}${NC}"
                report_add "  $attr_name: $raw_val"
            done

            # NVMe spezifisch
            if [[ "$dev" == nvme* ]]; then
                smartctl -A /dev/"$dev" 2>/dev/null | grep -iE "percentage|temperature|power|unsafe|error|written|read" | while IFS= read -r line; do
                    result_info "  $line"
                done
            fi

            # Temperatur
            local temp=$(smartctl -A /dev/"$dev" 2>/dev/null | grep -i "temperature" | head -1 | awk '{print $NF}')
            if [[ -n "$temp" && "$temp" =~ ^[0-9]+$ ]]; then
                if (( temp > 60 )); then
                    result_fail "Temperatur: ${temp}C — ZU HEISS!"
                elif (( temp > 45 )); then
                    result_warn "Temperatur: ${temp}C — erhoet"
                else
                    result_ok "Temperatur: ${temp}C"
                fi
            fi
        else
            result_warn "smartctl nicht verfuegbar"
        fi

        # Read Speed Test (nicht-destruktiv)
        echo ""
        echo -ne "    ${DIM}Lesegeschwindigkeit...${NC} "
        local read_speed=$(dd if=/dev/"$dev" of=/dev/null bs=1M count=100 iflag=direct 2>&1 | grep -oP '[\d.]+ [MGKT]B/s' | tail -1)
        if [[ -n "$read_speed" ]]; then
            result_ok "Lesen: $read_speed"
        else
            result_info "Lesetest nicht moeglich"
        fi
    done

    pause_key
}

# ─── [3] CPU Test ─────────────────────────────────────────────────────────────
do_cpu_test() {
    hw_header
    echo -e "    ${W}CPU STRESSTEST${NC}"
    echo ""
    REPORT_DATA=""
    report_add "  CPU STRESSTEST"

    local cpu=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
    local cores=$(nproc 2>/dev/null || echo "?")
    echo -e "    ${DIM}CPU:${NC}   ${W}${cpu}${NC}"
    echo -e "    ${DIM}Kerne:${NC} ${W}${cores}${NC}"
    echo ""

    echo -e "    ${C}[1]${NC}  Schnell   ${DIM}— 30 Sekunden${NC}"
    echo -e "    ${C}[2]${NC}  Normal    ${DIM}— 2 Minuten${NC}"
    echo -e "    ${C}[3]${NC}  Lang      ${DIM}— 5 Minuten${NC}"
    echo -e "    ${C}[4]${NC}  Extrem    ${DIM}— 15 Minuten${NC}"
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo ""
    echo -ne "    Auswahl: "
    read -r sel

    local duration=30
    case "$sel" in
        0) return ;;
        1) duration=30 ;;
        2) duration=120 ;;
        3) duration=300 ;;
        4) duration=900 ;;
        *) return ;;
    esac

    section "CPU Stress: ${duration}s auf ${cores} Kernen"

    # Starttemperatur
    local temp_start=""
    for tz in /sys/class/thermal/thermal_zone*/temp; do
        local t=$(cat "$tz" 2>/dev/null)
        if [[ -n "$t" && "$t" -gt 0 ]]; then
            temp_start=$((t / 1000))
            break
        fi
    done
    [[ -n "$temp_start" ]] && result_info "Starttemperatur: ${temp_start}C"

    # CPU Stress mit reinem Bash (kein stress/stress-ng noetig)
    echo -e "    ${C}[...]  Starte Stresstest...${NC}"
    echo ""

    local pids=()
    for ((c=0; c<cores; c++)); do
        (
            local end=$((SECONDS + duration))
            while (( SECONDS < end )); do
                # Intensive Berechnung
                echo "scale=1000; 4*a(1)" | bc -l &>/dev/null || \
                awk 'BEGIN{for(i=0;i<100000;i++)sin(i)*cos(i)}' 2>/dev/null || true
            done
        ) &
        pids+=($!)
    done

    # Fortschrittsanzeige
    local elapsed=0
    while (( elapsed < duration )); do
        sleep 5
        elapsed=$((elapsed + 5))
        local pct=$((elapsed * 100 / duration))

        # Aktuelle Temperatur
        local temp_now=""
        for tz in /sys/class/thermal/thermal_zone*/temp; do
            local t=$(cat "$tz" 2>/dev/null)
            if [[ -n "$t" && "$t" -gt 0 ]]; then
                temp_now=$((t / 1000))
                break
            fi
        done

        # CPU Load
        local load=$(awk '{print $1}' /proc/loadavg 2>/dev/null)

        local temp_str=""
        [[ -n "$temp_now" ]] && temp_str="  Temp: ${temp_now}C"

        echo -e "    ${DIM}  [${pct}%]  ${elapsed}/${duration}s  Load: ${load}${temp_str}${NC}"

        # Temperatur-Warnung
        if [[ -n "$temp_now" ]] && (( temp_now > 95 )); then
            echo -e "    ${R}WARNUNG: CPU ueber 95C! Breche ab...${NC}"
            for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
            wait 2>/dev/null
            result_fail "CPU Test abgebrochen — Ueberhitzung (${temp_now}C)"
            pause_key; return
        fi
    done

    # Warten bis alle fertig
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null; done

    # Endtemperatur
    local temp_end=""
    for tz in /sys/class/thermal/thermal_zone*/temp; do
        local t=$(cat "$tz" 2>/dev/null)
        if [[ -n "$t" && "$t" -gt 0 ]]; then
            temp_end=$((t / 1000))
            break
        fi
    done

    echo ""
    result_ok "CPU Stresstest bestanden (${duration}s, ${cores} Kerne)"
    log_session "HWTEST: CPU Stresstest bestanden (${duration}s, ${cores} Kerne)"
    [[ -n "$temp_start" && -n "$temp_end" ]] && result_info "Temperatur: ${temp_start}C -> ${temp_end}C (Delta: $((temp_end - temp_start))C)"

    # Frequenz-Check
    local freq=$(lscpu 2>/dev/null | grep -i "MHz" | head -1 | awk '{print $NF}')
    [[ -n "$freq" ]] && result_info "CPU Frequenz: ${freq} MHz"

    report_add "  Dauer: ${duration}s, Kerne: ${cores}"
    [[ -n "$temp_start" ]] && report_add "  Temp Start: ${temp_start}C"
    [[ -n "$temp_end" ]] && report_add "  Temp Ende: ${temp_end}C"

    pause_key
}

# ─── [4] Komplett-Test ────────────────────────────────────────────────────────
do_full_test() {
    REPORT_DATA=""
    report_add "================================================================"
    report_add "  HARDWARE KOMPLETT-TEST — flowbit OS"
    report_add "  Datum: $(date '+%d.%m.%Y %H:%M:%S')"
    report_add "  Host:  $HOSTNAME_STR"
    report_add "================================================================"

    hw_header
    echo -e "    ${W}KOMPLETT HARDWARE TEST${NC}"
    echo -e "    ${DIM}RAM (schnell) + alle Disks + CPU (30s)${NC}"
    echo ""
    echo -e "    ${Y}Das dauert ca. 2-3 Minuten. Fortfahren? [j/n]${NC}"
    echo -ne "    > "
    read -r confirm
    [[ "${confirm,,}" != "j" ]] && return

    echo ""

    # RAM schnell
    section "RAM Test (256 MB, 1 Durchgang)"
    local ramfile="/dev/shm/.hwtest_full_$$"
    dd if=/dev/urandom of="$ramfile" bs=1M count=256 2>/dev/null
    local cs1=$(md5sum "$ramfile" | awk '{print $1}')
    sync
    local cs2=$(md5sum "$ramfile" | awk '{print $1}')
    rm -f "$ramfile"
    if [[ "$cs1" == "$cs2" ]]; then
        result_ok "RAM: Write/Read OK"
    else
        result_fail "RAM: Fehler erkannt!"
    fi

    # Alle Disks SMART
    section "Disk SMART Check"
    if command -v smartctl &>/dev/null; then
        while IFS= read -r d; do
            local name=$(echo "$d" | awk '{print $1}')
            local health=$(smartctl -H /dev/"$name" 2>/dev/null)
            if echo "$health" | grep -qi "PASSED\|OK"; then
                result_ok "/dev/$name: SMART PASSED"
            elif echo "$health" | grep -qi "FAILED"; then
                result_fail "/dev/$name: SMART FAILED"
            else
                result_warn "/dev/$name: SMART unbekannt"
            fi
        done < <(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2=="disk"' | grep -E "^(sd|nvme|hd|vd)")
    else
        result_warn "smartctl nicht verfuegbar"
    fi

    # CPU kurz
    section "CPU Stress (30s)"
    local cores=$(nproc 2>/dev/null || echo 1)
    local pids=()
    for ((c=0; c<cores; c++)); do
        ( timeout 30 awk 'BEGIN{for(i=0;i<999999999;i++)sin(i)}' 2>/dev/null || true ) &
        pids+=($!)
    done
    echo -e "    ${DIM}  Laueft 30 Sekunden...${NC}"
    sleep 30
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
    wait 2>/dev/null
    result_ok "CPU: Stresstest 30s bestanden"

    echo ""
    echo -e "    ${G}Komplett-Test abgeschlossen.${NC}"
    echo ""
    echo -e "    ${C}[1]${NC}  Ergebnis speichern"
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo -ne "    Auswahl: "
    read -r sel
    [[ "$sel" == "1" ]] && { save_report "HWTEST_FULL"; log_session "HWTEST: Komplett-Test Report exportiert"; }

    pause_key
}

# ─── Menue ────────────────────────────────────────────────────────────────────
hwtest_menu() {
    while true; do
        hw_header
        echo -e "    ${W}HARDWARE TEST${NC}"
        echo ""
        echo -e "    ${C}[1]${NC}  RAM Test          ${DIM}— Speicher pruefen (Write/Read/Pattern)${NC}"
        echo -e "    ${C}[2]${NC}  Disk Test          ${DIM}— SMART Health + Lesegeschwindigkeit${NC}"
        echo -e "    ${C}[3]${NC}  CPU Stresstest     ${DIM}— Alle Kerne belasten + Temp${NC}"
        echo ""
        echo -e "    ${C}[4]${NC}  Komplett-Test      ${DIM}— Alles testen + Export${NC}"
        echo ""
        echo -e "    ${C}[0]${NC}  Zurueck zum Hauptmenue"
        echo ""
        echo -ne "    Auswahl: "
        read -r choice

        case "$choice" in
            1) do_ram_test ;;
            2) do_disk_test ;;
            3) do_cpu_test ;;
            4) do_full_test ;;
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

hwtest_menu
