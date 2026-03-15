#!/bin/bash
# =============================================================================
#  SYSTEM INFO — flowbit OS Modul | Hardware-Inventar & Intune Export
#  Teil von flowbit OS
# =============================================================================

set -uo pipefail

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

# ─── Hilfsfunktionen ─────────────────────────────────────────────────────────
sysinfo_header() {
    clear
    echo ""
    echo -e "${C}    ███████╗██╗   ██╗███████╗██╗███╗   ██╗███████╗ ██████╗ ${NC}"
    echo -e "${C}    ██╔════╝╚██╗ ██╔╝██╔════╝██║████╗  ██║██╔════╝██╔═══██╗${NC}"
    echo -e "${C}    ███████╗ ╚████╔╝ ███████╗██║██╔██╗ ██║█████╗  ██║   ██║${NC}"
    echo -e "${C}    ╚════██║  ╚██╔╝  ╚════██║██║██║╚██╗██║██╔══╝  ██║   ██║${NC}"
    echo -e "${C}    ███████║   ██║   ███████║██║██║ ╚████║██║     ╚██████╔╝${NC}"
    echo -e "${C}     ╚══════╝   ╚═╝   ╚══════╝╚═╝╚═╝  ╚═══╝╚═╝      ╚═════╝ ${NC}"
    echo -e "${DIM}    ──────────────────────────────────────────────────────${NC}"
    echo ""
}

pause_key() {
    echo ""
    echo -e "    ${DIM}[ Enter zum Fortfahren ]${NC}"
    read -r
}

# ─── Daten sammeln ────────────────────────────────────────────────────────────
get_val() {
    # Liest DMI/Sysfs Wert, fallback auf N/A
    local val
    val=$(cat "$1" 2>/dev/null | xargs)
    [[ -z "$val" || "$val" == "To Be Filled By O.E.M." || "$val" == "Default string" ]] && val="N/A"
    echo "$val"
}

get_dmi() {
    local val
    val=$(dmidecode -s "$1" 2>/dev/null | head -1 | xargs)
    [[ -z "$val" || "$val" == "To Be Filled By O.E.M." || "$val" == "Default string" || "$val" == "Not Specified" ]] && val="N/A"
    echo "$val"
}

get_manufacturer()  { get_dmi "system-manufacturer"; }
get_model()         { get_dmi "system-product-name"; }
get_serial()        { get_dmi "system-serial-number"; }
get_bios_vendor()   { get_dmi "bios-vendor"; }
get_bios_version()  { get_dmi "bios-version"; }
get_bios_date()     { get_dmi "bios-release-date"; }
get_board_vendor()  { get_dmi "baseboard-manufacturer"; }
get_board_model()   { get_dmi "baseboard-product-name"; }
get_board_serial()  { get_dmi "baseboard-serial-number"; }
get_uuid()          { get_dmi "system-uuid"; }
get_sku()           { get_dmi "system-sku-number"; }
get_family()        { get_dmi "system-family"; }

get_cpu() {
    grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "N/A"
}

get_cpu_cores() {
    local phys logical
    phys=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "?")
    logical=$(nproc 2>/dev/null || echo "?")
    echo "${phys} Threads / $(grep "^cpu cores" /proc/cpuinfo 2>/dev/null | head -1 | awk '{print $NF}' || echo '?') Kerne"
}

get_ram_total()  { free -h | awk '/^Mem:/{print $2}'; }
get_ram_detail() {
    dmidecode -t memory 2>/dev/null | awk '
    /^Memory Device$/     { slot=""; size=""; speed=""; type=""; locator="" }
    /^\tSize:/            { size=$2" "$3 }
    /^\tType:/            { type=$2 }
    /^\tSpeed:/           { speed=$2" "$3 }
    /^\tLocator:/         { locator=$2 }
    /^\tSerial Number:/   { serial=$3 }
    /^$/                  { if (size != "" && size != "No") printf "    %-10s  %-10s  %-8s  %s  SN: %s\n", locator, size, type, speed, serial }
    '
}

get_intune_hash() {
    # Hardware Hash fuer Intune/Autopilot
    # Besteht aus: Hersteller + Modell + Seriennummer + UUID + SKU + Board-Serial
    # Microsoft nutzt WMI, wir lesen die gleichen SMBIOS-Felder
    local hash_source=""
    hash_source+="$(get_manufacturer)|"
    hash_source+="$(get_model)|"
    hash_source+="$(get_serial)|"
    hash_source+="$(get_uuid)|"
    hash_source+="$(get_sku)|"
    hash_source+="$(get_board_serial)"
    echo "$hash_source"
}

get_autopilot_csv_hash() {
    # Der echte Autopilot Hardware Hash kommt aus ACPI (WMI BIOS Interface)
    # Unter Linux: /sys/firmware/acpi/tables/MSDM oder via dmidecode OEM strings
    local hw_hash=""
    # Methode 1: OA3 / MSDM Tabelle (Windows Product Key)
    if [[ -f /sys/firmware/acpi/tables/MSDM ]]; then
        hw_hash="MSDM vorhanden"
    fi
    # Methode 2: Aus WMI/MOF (nur teilweise unter Linux moeglich)
    # Der volle 4096-byte Hash ist nur unter Windows zugreifbar
    # Wir liefern stattdessen alle relevanten Felder einzeln
    echo "$hw_hash"
}

get_secureboot() {
    if [[ -d /sys/firmware/efi ]]; then
        local sb
        sb=$(od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | awk '{print $NF}')
        if [[ "$sb" == "1" ]]; then
            echo "UEFI + Secure Boot AN"
        else
            echo "UEFI + Secure Boot AUS"
        fi
    else
        echo "Legacy BIOS (kein UEFI)"
    fi
}

get_tpm() {
    if [[ -c /dev/tpm0 || -c /dev/tpmrm0 ]]; then
        local ver
        ver=$(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null || echo "?")
        echo "TPM ${ver}.0 vorhanden"
    elif [[ -d /sys/class/tpm/tpm0 ]]; then
        echo "TPM vorhanden"
    else
        echo "Kein TPM erkannt"
    fi
}

get_windows_key() {
    # OEM Windows Key aus ACPI/MSDM
    if [[ -f /sys/firmware/acpi/tables/MSDM ]]; then
        strings /sys/firmware/acpi/tables/MSDM 2>/dev/null | grep -oE '[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}' | head -1 || echo "N/A"
    else
        echo "Kein OEM-Key im BIOS"
    fi
}

get_battery() {
    local bat_path="/sys/class/power_supply/BAT0"
    if [[ -d "$bat_path" ]]; then
        local status capacity cycle health
        status=$(cat "$bat_path/status" 2>/dev/null || echo "?")
        capacity=$(cat "$bat_path/capacity" 2>/dev/null || echo "?")
        cycle=$(cat "$bat_path/cycle_count" 2>/dev/null || echo "?")
        local full=$(cat "$bat_path/energy_full" 2>/dev/null || echo 0)
        local design=$(cat "$bat_path/energy_full_design" 2>/dev/null || echo 0)
        if (( design > 0 )); then
            health=$(( full * 100 / design ))
        else
            health="?"
        fi
        echo "${capacity}% | Health: ${health}% | Zyklen: ${cycle} | ${status}"
    else
        echo "Kein Akku (Desktop)"
    fi
}

# ─── Anzeige ──────────────────────────────────────────────────────────────────
show_all_info() {
    sysinfo_header

    echo -e "    ${C}── Geraet ──────────────────────────────────────────${NC}"
    echo -e "    ${DIM}Hersteller:${NC}    ${W}$(get_manufacturer)${NC}"
    echo -e "    ${DIM}Modell:${NC}        ${W}$(get_model)${NC}"
    echo -e "    ${DIM}Familie:${NC}       ${W}$(get_family)${NC}"
    echo -e "    ${DIM}SKU:${NC}           ${W}$(get_sku)${NC}"
    echo -e "    ${DIM}Seriennummer:${NC}  ${W}$(get_serial)${NC}"
    echo -e "    ${DIM}UUID:${NC}          ${W}$(get_uuid)${NC}"

    echo ""
    echo -e "    ${C}── BIOS / Firmware ─────────────────────────────────${NC}"
    echo -e "    ${DIM}BIOS Vendor:${NC}   ${W}$(get_bios_vendor)${NC}"
    echo -e "    ${DIM}BIOS Version:${NC}  ${W}$(get_bios_version)${NC}"
    echo -e "    ${DIM}BIOS Datum:${NC}    ${W}$(get_bios_date)${NC}"
    echo -e "    ${DIM}Boot-Modus:${NC}    ${W}$(get_secureboot)${NC}"
    echo -e "    ${DIM}TPM:${NC}           ${W}$(get_tpm)${NC}"
    echo -e "    ${DIM}Windows Key:${NC}   ${W}$(get_windows_key)${NC}"

    echo ""
    echo -e "    ${C}── Mainboard ───────────────────────────────────────${NC}"
    echo -e "    ${DIM}Hersteller:${NC}    ${W}$(get_board_vendor)${NC}"
    echo -e "    ${DIM}Modell:${NC}        ${W}$(get_board_model)${NC}"
    echo -e "    ${DIM}Seriennummer:${NC}  ${W}$(get_board_serial)${NC}"

    echo ""
    echo -e "    ${C}── Prozessor ───────────────────────────────────────${NC}"
    echo -e "    ${DIM}CPU:${NC}           ${W}$(get_cpu)${NC}"
    echo -e "    ${DIM}Kerne:${NC}         ${W}$(get_cpu_cores)${NC}"

    echo ""
    echo -e "    ${C}── Arbeitsspeicher ($(get_ram_total) gesamt) ─────────────────${NC}"
    get_ram_detail | while IFS= read -r line; do
        echo -e "    ${W}${line}${NC}"
    done

    echo ""
    echo -e "    ${C}── Datentraeger ────────────────────────────────────${NC}"
    while IFS= read -r line; do
        local name size model serial rota dtype
        name=$(echo "$line" | awk '{print $1}')
        rota=$(lsblk -d -n -o ROTA /dev/"$name" 2>/dev/null | xargs)
        size=$(lsblk -d -n -o SIZE /dev/"$name" 2>/dev/null | xargs)
        model=$(lsblk -d -n -o MODEL /dev/"$name" 2>/dev/null | xargs)
        serial=$(lsblk -d -n -o SERIAL /dev/"$name" 2>/dev/null | xargs)
        [[ -z "$serial" ]] && serial=$(smartctl -i /dev/"$name" 2>/dev/null | awk '/Serial Number/{print $NF}' || echo "N/A")
        [[ "$rota" == "0" ]] && dtype="${C}SSD${NC}" || dtype="${R}HDD${NC}"
        echo -e "    /dev/${W}${name}${NC}  ${dtype}  ${Y}${size}${NC}  ${DIM}${model}${NC}  SN: ${W}${serial:-N/A}${NC}"
    done < <(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2=="disk"' | grep -E "^(sd|nvme|hd|vd)")

    echo ""
    echo -e "    ${C}── Netzwerk ────────────────────────────────────────${NC}"
    for iface in /sys/class/net/*; do
        local name=$(basename "$iface")
        [[ "$name" == "lo" ]] && continue
        local mac=$(cat "$iface/address" 2>/dev/null || echo "N/A")
        local ip=$(ip -4 addr show "$name" 2>/dev/null | awk '/inet /{print $2}' | head -1)
        local state=$(cat "$iface/operstate" 2>/dev/null || echo "?")
        echo -e "    ${W}${name}${NC}  MAC: ${DIM}${mac}${NC}  IP: ${W}${ip:-keine}${NC}  ${DIM}(${state})${NC}"
    done

    echo ""
    echo -e "    ${C}── Akku ────────────────────────────────────────────${NC}"
    echo -e "    ${W}$(get_battery)${NC}"

    echo ""
    echo -e "    ${C}── Intune / Autopilot ──────────────────────────────${NC}"
    echo -e "    ${DIM}Hardware-Identifikation:${NC}"
    echo -e "    ${W}$(get_intune_hash)${NC}"
    local msdm_status=$(get_autopilot_csv_hash)
    [[ -n "$msdm_status" ]] && echo -e "    ${DIM}MSDM:${NC} ${W}${msdm_status}${NC}"
    echo -e "    ${DIM}Hinweis: Voller Autopilot-Hash (4K) nur unter Windows auslesbar.${NC}"
    echo -e "    ${DIM}Alle relevanten Felder (SN, UUID, SKU) werden im Export erfasst.${NC}"
}

# ─── Export ───────────────────────────────────────────────────────────────────
export_report() {
    local serial=$(get_serial)
    local model=$(get_model)
    local manufacturer=$(get_manufacturer)
    local filename="SYSINFO_${serial}_${TIMESTAMP}.txt"

    {
        echo "================================================================"
        echo "  SYSTEM INFO — flowbit OS"
        echo "================================================================"
        echo ""
        echo "  Datum           : $(date '+%d.%m.%Y %H:%M:%S')"
        echo "  Hostname        : $HOSTNAME_STR"
        echo ""
        echo "  GERAET"
        echo "  ────────────────────────────────────────────────"
        echo "  Hersteller      : $manufacturer"
        echo "  Modell          : $model"
        echo "  Familie         : $(get_family)"
        echo "  SKU             : $(get_sku)"
        echo "  Seriennummer    : $serial"
        echo "  UUID            : $(get_uuid)"
        echo ""
        echo "  BIOS / FIRMWARE"
        echo "  ────────────────────────────────────────────────"
        echo "  BIOS Vendor     : $(get_bios_vendor)"
        echo "  BIOS Version    : $(get_bios_version)"
        echo "  BIOS Datum      : $(get_bios_date)"
        echo "  Boot-Modus      : $(get_secureboot)"
        echo "  TPM             : $(get_tpm)"
        echo "  Windows OEM Key : $(get_windows_key)"
        echo ""
        echo "  MAINBOARD"
        echo "  ────────────────────────────────────────────────"
        echo "  Hersteller      : $(get_board_vendor)"
        echo "  Modell          : $(get_board_model)"
        echo "  Seriennummer    : $(get_board_serial)"
        echo ""
        echo "  PROZESSOR"
        echo "  ────────────────────────────────────────────────"
        echo "  CPU             : $(get_cpu)"
        echo "  Kerne           : $(get_cpu_cores)"
        echo ""
        echo "  ARBEITSSPEICHER"
        echo "  ────────────────────────────────────────────────"
        echo "  Total           : $(get_ram_total)"
        get_ram_detail
        echo ""
        echo "  DATENTRAEGER"
        echo "  ────────────────────────────────────────────────"
        lsblk -d -o NAME,SIZE,TYPE,ROTA,MODEL,SERIAL 2>/dev/null | grep -E "(NAME|sd|nvme|hd|vd)"
        echo ""
        echo "  SMART Status:"
        while IFS= read -r d; do
            local name=$(echo "$d" | awk '{print $1}')
            echo "  --- /dev/$name ---"
            smartctl -H /dev/"$name" 2>/dev/null | grep -E "result|Status" || echo "  (nicht verfuegbar)"
        done < <(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2=="disk"' | grep -E "^(sd|nvme|hd|vd)")
        echo ""
        echo "  NETZWERK"
        echo "  ────────────────────────────────────────────────"
        for iface in /sys/class/net/*; do
            local name=$(basename "$iface")
            [[ "$name" == "lo" ]] && continue
            local mac=$(cat "$iface/address" 2>/dev/null)
            local ip=$(ip -4 addr show "$name" 2>/dev/null | awk '/inet /{print $2}' | head -1)
            echo "  $name  MAC: $mac  IP: ${ip:-keine}"
        done
        echo ""
        echo "  AKKU"
        echo "  ────────────────────────────────────────────────"
        echo "  $(get_battery)"
        echo ""
        echo "  INTUNE / AUTOPILOT"
        echo "  ────────────────────────────────────────────────"
        echo "  Hersteller      : $manufacturer"
        echo "  Modell          : $model"
        echo "  Seriennummer    : $serial"
        echo "  UUID            : $(get_uuid)"
        echo "  SKU             : $(get_sku)"
        echo "  Board Serial    : $(get_board_serial)"
        echo "  Hash-Quelle     : $(get_intune_hash)"
        echo ""
        echo "================================================================"
        echo "  Erstellt mit flowbit OS System Info"
        echo "================================================================"
    } > "/tmp/$filename"

    # USB suchen
    local usb_path=""
    for mp in /mnt/usb* /mnt/*/  /run/media/*/*/; do
        [[ -w "$mp" ]] && usb_path="$mp" && break
    done

    if [[ -n "$usb_path" ]]; then
        cp "/tmp/$filename" "${usb_path}${filename}"
        echo -e "    ${G}[OK] Gespeichert: ${usb_path}${filename}${NC}"
    else
        echo -e "    ${Y}Kein USB gefunden. Gespeichert: /tmp/${filename}${NC}"
    fi
}

export_intune_csv() {
    local serial=$(get_serial)
    local filename="INTUNE_${serial}_${TIMESTAMP}.csv"

    {
        echo "Device Serial Number,Windows Product ID,Hardware Hash,Manufacturer,Model Name,UUID,SKU,Board Serial"
        echo "\"$serial\",\"$(get_windows_key)\",\"$(get_intune_hash)\",\"$(get_manufacturer)\",\"$(get_model)\",\"$(get_uuid)\",\"$(get_sku)\",\"$(get_board_serial)\""
    } > "/tmp/$filename"

    local usb_path=""
    for mp in /mnt/usb* /mnt/*/  /run/media/*/*/; do
        [[ -w "$mp" ]] && usb_path="$mp" && break
    done

    if [[ -n "$usb_path" ]]; then
        cp "/tmp/$filename" "${usb_path}${filename}"
        echo -e "    ${G}[OK] Gespeichert: ${usb_path}${filename}${NC}"
    else
        echo -e "    ${Y}Kein USB gefunden. Gespeichert: /tmp/${filename}${NC}"
    fi
}

# ─── Menue ────────────────────────────────────────────────────────────────────
sysinfo_menu() {
    while true; do
        sysinfo_header
        echo -e "    ${W}SYSTEM INFO${NC}"
        echo ""
        echo -e "    ${C}[1]${NC}  Alle Infos anzeigen"
        echo -e "    ${C}[2]${NC}  Report exportieren          ${DIM}— Vollstaendige TXT-Datei${NC}"
        echo -e "    ${C}[3]${NC}  Intune CSV exportieren      ${DIM}— SN, UUID, SKU fuer Autopilot${NC}"
        echo ""
        echo -e "    ${C}[0]${NC}  Zurueck zum Hauptmenue"
        echo ""
        echo -ne "    Auswahl: "
        read -r choice

        case "$choice" in
            1)
                show_all_info
                pause_key
                ;;
            2)
                show_all_info
                echo ""
                export_report
                pause_key
                ;;
            3)
                export_intune_csv
                pause_key
                ;;
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

sysinfo_menu
