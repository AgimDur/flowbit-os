#!/bin/bash
# =============================================================================
#  BIOS TOOLS — flowbit OS Modul | BIOS Settings, Profile, TPM, Secure Boot
#  Teil von flowbit OS
# =============================================================================

set -uo pipefail
source /opt/kit/modules/common.sh 2>/dev/null

R='\033[1;31m'
G='\033[1;32m'
Y='\033[1;33m'
C='\033[0;36m'
W='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'

HOSTNAME_STR=$(hostname 2>/dev/null || echo "unbekannt")
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_DATA=""

# Pfade fuer BIOS Profile
PROFILES_DIR="/opt/kit/bios_profiles"
USB_PROFILES_DIR=""  # wird dynamisch gesetzt

# Firmware Attributes Pfad (Dell/HP/Lenovo)
FW_ATTR_PATH=""
for p in /sys/class/firmware-attributes/*/attributes; do
    [[ -d "$p" ]] && FW_ATTR_PATH="$p" && break
done

bios_header() {
    clear
    echo ""
    echo -e "${C}    ██████╗ ██╗ ██████╗ ███████╗${NC}"
    echo -e "${C}    ██╔══██╗██║██╔═══██╗██╔════╝${NC}"
    echo -e "${C}    ██████╔╝██║██║   ██║███████╗${NC}"
    echo -e "${C}    ██╔══██╗██║██║   ██║╚════██║${NC}"
    echo -e "${C}    ██████╔╝██║╚██████╔╝███████║${NC}"
    echo -e "${C}    ╚═════╝ ╚═╝ ╚═════╝ ╚══════╝${NC}"
    echo -e "${DIM}    ──────────────────────────────────────────────${NC}"
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
result_line() {
    printf "    ${DIM}%-22s${NC} ${W}%s${NC}\n" "$1" "$2"
    report_add "  $(printf '%-22s %s' "$1" "$2")"
}

section() {
    echo ""
    echo -e "    ${C}── $1 ──────────────────────────────────────────${NC}"
    echo ""
    report_add ""
    report_add "  $1"
    report_add "  ────────────────────────────────────────────────"
}

get_dmi() {
    local val
    val=$(dmidecode -s "$1" 2>/dev/null | head -1 | xargs)
    [[ -z "$val" || "$val" == "To Be Filled By O.E.M." || "$val" == "Default string" || "$val" == "Not Specified" ]] && val="N/A"
    echo "$val"
}

save_report() {
    local prefix="${1:-BIOS}"
    local serial=$(get_dmi "system-serial-number")
    local filename="${prefix}_${serial}_${TIMESTAMP}.txt"
    {
        echo "================================================================"
        echo "  BIOS TOOLS — flowbit OS"
        echo "  Datum: $(date '+%d.%m.%Y %H:%M:%S')"
        echo "  Host:  $HOSTNAME_STR"
        echo "================================================================"
        echo "$REPORT_DATA"
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

# USB Profiles Ordner finden/erstellen
find_usb_profiles() {
    USB_PROFILES_DIR=""
    for mp in /mnt/usb* /mnt/*/  /run/media/*/*/; do
        if [[ -d "$mp" && -w "$mp" ]]; then
            local bdir="${mp}BIOS_Settings"
            mkdir -p "$bdir" 2>/dev/null
            USB_PROFILES_DIR="$bdir"
            return 0
        fi
    done
    return 1
}

# ─── [1] BIOS/UEFI Uebersicht ────────────────────────────────────────────────
do_bios_overview() {
    bios_header
    echo -e "    ${W}BIOS / UEFI UEBERSICHT${NC}"
    REPORT_DATA=""

    section "Firmware"
    result_line "BIOS Vendor:" "$(get_dmi bios-vendor)"
    result_line "BIOS Version:" "$(get_dmi bios-version)"
    result_line "BIOS Datum:" "$(get_dmi bios-release-date)"
    result_line "BIOS Revision:" "$(get_dmi bios-revision)"

    if [[ -d /sys/firmware/efi ]]; then
        result_line "Boot-Modus:" "UEFI"
    else
        result_line "Boot-Modus:" "Legacy BIOS (CSM)"
    fi

    section "System"
    result_line "Hersteller:" "$(get_dmi system-manufacturer)"
    result_line "Modell:" "$(get_dmi system-product-name)"
    result_line "Seriennummer:" "$(get_dmi system-serial-number)"
    result_line "UUID:" "$(get_dmi system-uuid)"
    result_line "SKU:" "$(get_dmi system-sku-number)"
    result_line "Familie:" "$(get_dmi system-family)"

    section "Mainboard"
    result_line "Hersteller:" "$(get_dmi baseboard-manufacturer)"
    result_line "Modell:" "$(get_dmi baseboard-product-name)"
    result_line "Seriennummer:" "$(get_dmi baseboard-serial-number)"
    result_line "Asset Tag:" "$(get_dmi baseboard-asset-tag)"

    section "Chassis"
    result_line "Typ:" "$(get_dmi chassis-type)"
    result_line "Seriennummer:" "$(get_dmi chassis-serial-number)"
    result_line "Asset Tag:" "$(get_dmi chassis-asset-tag)"

    pause_key
}

# ─── [2] Secure Boot ─────────────────────────────────────────────────────────
do_secureboot() {
    bios_header
    echo -e "    ${W}SECURE BOOT STATUS${NC}"
    REPORT_DATA=""

    section "Boot-Modus"
    if [[ ! -d /sys/firmware/efi ]]; then
        result_warn "Legacy BIOS — Secure Boot nicht verfuegbar"
        pause_key; return
    fi

    result_ok "UEFI-Modus aktiv"
    local sb_val=""
    for f in /sys/firmware/efi/efivars/SecureBoot-*; do
        [[ -f "$f" ]] && sb_val=$(od -An -t u1 "$f" 2>/dev/null | awk '{print $NF}') && break
    done
    if [[ "$sb_val" == "1" ]]; then
        result_ok "Secure Boot: AKTIVIERT"
    else
        result_warn "Secure Boot: DEAKTIVIERT"
    fi

    section "EFI Boot-Eintraege"
    if command -v efibootmgr &>/dev/null; then
        efibootmgr -v 2>/dev/null | while IFS= read -r line; do
            echo -e "    ${DIM}${line}${NC}"
        done
    fi

    pause_key
}

# ─── [3] TPM ─────────────────────────────────────────────────────────────────
do_tpm() {
    bios_header
    echo -e "    ${W}TPM STATUS${NC}"
    REPORT_DATA=""

    section "TPM Erkennung"
    if [[ -d /sys/class/tpm/tpm0 ]]; then
        local tpm_ver=$(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null || echo "?")
        result_ok "TPM ${tpm_ver}.0 vorhanden"
    else
        result_warn "Kein TPM erkannt (evtl. im BIOS deaktiviert)"
    fi

    section "Windows 11 Check"
    local w11_ok=true
    local tpm_ver=$(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null || echo "0")
    [[ "$tpm_ver" == "2" ]] && result_ok "TPM 2.0" || { result_fail "TPM 2.0 fehlt"; w11_ok=false; }
    [[ -d /sys/firmware/efi ]] && result_ok "UEFI" || { result_fail "Kein UEFI"; w11_ok=false; }
    echo ""
    $w11_ok && result_ok "Windows 11 kompatibel" || result_warn "Windows 11 NICHT kompatibel"

    if command -v tpm2_getcap &>/dev/null; then
        section "TPM Details"
        tpm2_getcap properties-fixed 2>/dev/null | grep -E "manufacturer|firmware|family" | while IFS= read -r line; do
            result_info "  $line"
        done
    fi

    pause_key
}

# ─── [4] Asset Tag / IDs ─────────────────────────────────────────────────────
do_asset_tag() {
    bios_header
    echo -e "    ${W}ASSET TAG / IDENTIFIKATION${NC}"
    REPORT_DATA=""

    section "IDs"
    result_line "System SN:" "$(get_dmi system-serial-number)"
    result_line "Board SN:" "$(get_dmi baseboard-serial-number)"
    result_line "Chassis SN:" "$(get_dmi chassis-serial-number)"
    result_line "UUID:" "$(get_dmi system-uuid)"
    result_line "SKU:" "$(get_dmi system-sku-number)"
    result_line "Chassis Asset Tag:" "$(get_dmi chassis-asset-tag)"
    result_line "Board Asset Tag:" "$(get_dmi baseboard-asset-tag)"

    section "Windows Key (OEM/MSDM)"
    if [[ -f /sys/firmware/acpi/tables/MSDM ]]; then
        local key=$(strings /sys/firmware/acpi/tables/MSDM 2>/dev/null | grep -oE '[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}' | head -1)
        [[ -n "$key" ]] && result_ok "OEM Key: $key" || result_info "MSDM vorhanden, Key nicht lesbar"
    else
        result_info "Kein OEM Key im BIOS"
    fi

    section "Intune / Autopilot"
    result_line "Hersteller:" "$(get_dmi system-manufacturer)"
    result_line "Modell:" "$(get_dmi system-product-name)"
    result_line "Seriennummer:" "$(get_dmi system-serial-number)"
    result_line "UUID:" "$(get_dmi system-uuid)"
    result_line "SKU:" "$(get_dmi system-sku-number)"

    pause_key
}

# ─── [5] BIOS Settings auslesen ──────────────────────────────────────────────
do_read_settings() {
    bios_header
    echo -e "    ${W}BIOS SETTINGS AUSLESEN${NC}"
    REPORT_DATA=""
    report_add "  BIOS SETTINGS"
    report_add "  Datum: $(date '+%d.%m.%Y %H:%M:%S')"
    report_add "  Host: $HOSTNAME_STR"
    report_add "  Hersteller: $(get_dmi system-manufacturer)"
    report_add "  Modell: $(get_dmi system-product-name)"
    report_add "  SN: $(get_dmi system-serial-number)"

    if [[ -z "$FW_ATTR_PATH" ]]; then
        echo ""
        result_warn "Firmware Attributes nicht verfuegbar"
        result_info "Moeglich Gruende:"
        result_info "  - Hersteller wird nicht unterstuetzt"
        result_info "  - Kernel-Modul nicht geladen"
        result_info "  - VM statt echter Hardware"
        echo ""
        result_info "Unterstuetzte Hersteller: Dell, HP, Lenovo (Kernel 5.18+)"
        echo ""
        echo -e "    ${C}[1]${NC}  Trotzdem DMI/SMBIOS Settings exportieren"
        echo -e "    ${C}[0]${NC}  Zurueck"
        echo -ne "    Auswahl: "
        read -r sel
        if [[ "$sel" == "1" ]]; then
            do_dmi_export
        fi
        return
    fi

    local vendor=$(get_dmi system-manufacturer)
    result_ok "Firmware Attributes gefunden ($vendor)"
    echo ""

    local settings_count=0
    local settings_data=""

    section "Alle BIOS Settings"

    for attr_dir in "$FW_ATTR_PATH"/*/; do
        [[ ! -d "$attr_dir" ]] && continue
        local attr_name=$(basename "$attr_dir")
        local current_val=""
        local possible_vals=""
        local attr_type=""

        # Aktuellen Wert lesen
        if [[ -f "$attr_dir/current_value" ]]; then
            current_val=$(cat "$attr_dir/current_value" 2>/dev/null | xargs)
        fi

        # Moegliche Werte
        if [[ -f "$attr_dir/possible_values" ]]; then
            possible_vals=$(cat "$attr_dir/possible_values" 2>/dev/null | xargs)
        fi

        # Typ
        if [[ -f "$attr_dir/type" ]]; then
            attr_type=$(cat "$attr_dir/type" 2>/dev/null | xargs)
        fi

        # Anzeige
        if [[ -n "$current_val" ]]; then
            echo -e "    ${W}${attr_name}${NC}"
            echo -e "      ${DIM}Wert:${NC}     ${G}${current_val}${NC}"
            [[ -n "$possible_vals" ]] && echo -e "      ${DIM}Optionen:${NC} ${DIM}${possible_vals}${NC}"
            echo ""

            settings_data+="${attr_name}=${current_val}"$'\n'
            report_add "  ${attr_name} = ${current_val}"
            [[ -n "$possible_vals" ]] && report_add "    Optionen: ${possible_vals}"
            ((settings_count++))
        fi
    done

    echo -e "    ${DIM}────────────────────────────────────────────────${NC}"
    echo -e "    ${W}${settings_count} Settings gefunden.${NC}"
    echo ""

    echo -e "    ${C}[1]${NC}  Als TXT exportieren (alle Settings)"
    echo -e "    ${C}[2]${NC}  Als Profil speichern (zum Wiederverwenden)"
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo ""
    echo -ne "    Auswahl: "
    read -r sel

    case "$sel" in
        1) save_settings_txt "$settings_data" ;;
        2) save_as_profile "$settings_data" ;;
    esac
}

do_dmi_export() {
    section "DMI/SMBIOS Dump"
    local serial=$(get_dmi system-serial-number)
    local filename="BIOS_DMI_${serial}_${TIMESTAMP}.txt"

    {
        echo "================================================================"
        echo "  BIOS DMI DUMP — flowbit OS"
        echo "  Datum: $(date '+%d.%m.%Y %H:%M:%S')"
        echo "  Host: $HOSTNAME_STR"
        echo "  Hersteller: $(get_dmi system-manufacturer)"
        echo "  Modell: $(get_dmi system-product-name)"
        echo "  SN: $(get_dmi system-serial-number)"
        echo "================================================================"
        echo ""
        dmidecode 2>/dev/null
    } > "/tmp/$filename"

    local usb_path=""
    usb_path=$(find_usb_storage)
    if [[ -n "$usb_path" ]]; then
        mkdir -p "${usb_path}BIOS_Settings" 2>/dev/null
        cp "/tmp/$filename" "${usb_path}BIOS_Settings/${filename}"
        result_ok "Gespeichert: ${usb_path}BIOS_Settings/${filename}"
    else
        result_ok "Gespeichert: /tmp/${filename}"
    fi
    pause_key
}

save_settings_txt() {
    local data="$1"
    local serial=$(get_dmi system-serial-number)
    local model=$(get_dmi system-product-name)
    local filename="BIOS_Settings_${model}_${serial}_${TIMESTAMP}.txt"

    {
        echo "================================================================"
        echo "  BIOS SETTINGS EXPORT — flowbit OS"
        echo "  Datum      : $(date '+%d.%m.%Y %H:%M:%S')"
        echo "  Hersteller : $(get_dmi system-manufacturer)"
        echo "  Modell     : $model"
        echo "  SN         : $serial"
        echo "  BIOS       : $(get_dmi bios-version) ($(get_dmi bios-release-date))"
        echo "================================================================"
        echo ""
        echo "$REPORT_DATA"
        echo ""
        echo "================================================================"
    } > "/tmp/$filename"

    local usb_path=""
    usb_path=$(find_usb_storage)
    if [[ -n "$usb_path" ]]; then
        mkdir -p "${usb_path}BIOS_Settings" 2>/dev/null
        cp "/tmp/$filename" "${usb_path}BIOS_Settings/${filename}"
        result_ok "Gespeichert: ${usb_path}BIOS_Settings/${filename}"
    else
        result_ok "Gespeichert: /tmp/${filename}"
    fi
    pause_key
}

# ─── [6] BIOS Profil speichern ───────────────────────────────────────────────
save_as_profile() {
    local data="$1"

    echo ""
    echo -ne "    ${W}Profilname eingeben (z.B. Dell_Standard):${NC} "
    read -r profile_name
    [[ -z "$profile_name" ]] && { echo -e "    ${R}Kein Name eingegeben.${NC}"; pause_key; return; }

    # Sonderzeichen entfernen
    profile_name=$(echo "$profile_name" | tr ' ' '_' | tr -cd 'A-Za-z0-9_-')

    local profile_file="${profile_name}.biosprofile"

    # Profil-Datei erstellen
    local profile_content=""
    profile_content+="# flowbit OS BIOS Profil"$'\n'
    profile_content+="# Name: ${profile_name}"$'\n'
    profile_content+="# Erstellt: $(date '+%d.%m.%Y %H:%M:%S')"$'\n'
    profile_content+="# Quelle: $(get_dmi system-manufacturer) $(get_dmi system-product-name) (SN: $(get_dmi system-serial-number))"$'\n'
    profile_content+="# BIOS: $(get_dmi bios-version)"$'\n'
    profile_content+="#"$'\n'
    profile_content+="# Format: SettingName=Value"$'\n'
    profile_content+="# Zeilen mit # sind Kommentare"$'\n'
    profile_content+="# Nicht gewuenschte Settings mit # auskommentieren"$'\n'
    profile_content+="#"$'\n'
    profile_content+="$data"

    # Lokal speichern
    mkdir -p "$PROFILES_DIR" 2>/dev/null
    echo "$profile_content" > "${PROFILES_DIR}/${profile_file}"
    result_ok "Lokal gespeichert: ${PROFILES_DIR}/${profile_file}"

    # Auf USB speichern
    if find_usb_profiles; then
        echo "$profile_content" > "${USB_PROFILES_DIR}/${profile_file}"
        result_ok "USB gespeichert: ${USB_PROFILES_DIR}/${profile_file}"
    fi

    echo ""
    result_info "Profil kann bearbeitet werden (Textdatei)."
    result_info "Ungewuenschte Settings mit # auskommentieren."
    pause_key
}

# ─── [7] BIOS Profil laden & anwenden ────────────────────────────────────────
do_apply_profile() {
    bios_header
    echo -e "    ${W}BIOS PROFIL LADEN & ANWENDEN${NC}"
    echo ""
    echo -e "    ${Y}Hinweis: BIOS-Schreibzugriff funktioniert nur auf Dell, Lenovo und einigen HP Systemen.${NC}"
    echo -e "    ${Y}Auf anderen Herstellern wird der Befehl ohne Effekt ausgefuehrt.${NC}"
    echo ""

    if [[ -z "$FW_ATTR_PATH" ]]; then
        result_warn "Firmware Attributes nicht verfuegbar — Settings koennen nicht geschrieben werden"
        result_info "Profil kann nur auf Systemen mit Firmware Attributes angewendet werden"
        pause_key; return
    fi

    # Profile sammeln aus allen Quellen
    local profiles=()
    local profile_sources=()

    # Lokale Profile
    if [[ -d "$PROFILES_DIR" ]]; then
        while IFS= read -r f; do
            profiles+=("$f")
            profile_sources+=("Lokal")
        done < <(find "$PROFILES_DIR" -name "*.biosprofile" -type f 2>/dev/null | sort)
    fi

    # USB Profile
    for mp in /mnt/usb* /mnt/*/  /run/media/*/*/; do
        local bdir="${mp}BIOS_Settings"
        if [[ -d "$bdir" ]]; then
            while IFS= read -r f; do
                # Nicht doppelt hinzufuegen
                local fname=$(basename "$f")
                local already=false
                for existing in "${profiles[@]}"; do
                    [[ "$(basename "$existing")" == "$fname" ]] && already=true && break
                done
                $already || { profiles+=("$f"); profile_sources+=("USB: $mp"); }
            done < <(find "$bdir" -name "*.biosprofile" -type f 2>/dev/null | sort)
        fi
    done

    if [[ ${#profiles[@]} -eq 0 ]]; then
        result_warn "Keine Profile gefunden."
        result_info "Profile koennen erstellt werden unter:"
        result_info "  - [5] BIOS Settings auslesen -> Als Profil speichern"
        result_info "  - USB-Stick: BIOS_Settings/*.biosprofile"
        pause_key; return
    fi

    section "Verfuegbare Profile"
    for i in "${!profiles[@]}"; do
        local fname=$(basename "${profiles[$i]}" .biosprofile)
        local source="${profile_sources[$i]}"
        local created=$(grep "^# Erstellt:" "${profiles[$i]}" 2>/dev/null | cut -d: -f2- | xargs)
        local from_device=$(grep "^# Quelle:" "${profiles[$i]}" 2>/dev/null | cut -d: -f2- | xargs)
        echo -e "    ${C}[$((i+1))]${NC}  ${W}${fname}${NC}"
        echo -e "         ${DIM}${source} | ${created} | ${from_device}${NC}"
    done
    echo ""
    echo -e "    ${C}[v]${NC}  Profil anzeigen (ohne anzuwenden)"
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo ""
    echo -ne "    Auswahl: "
    read -r sel

    [[ "$sel" == "0" ]] && return

    # Profil anzeigen
    if [[ "$sel" == "v" || "$sel" == "V" ]]; then
        echo -ne "    Welches Profil (Nummer)? "
        read -r vsel
        if [[ "$vsel" =~ ^[0-9]+$ ]] && (( vsel >= 1 && vsel <= ${#profiles[@]} )); then
            echo ""
            section "Inhalt: $(basename "${profiles[$((vsel-1))]}" .biosprofile)"
            cat "${profiles[$((vsel-1))]}" | while IFS= read -r line; do
                if [[ "$line" == \#* ]]; then
                    echo -e "    ${DIM}${line}${NC}"
                else
                    local sname="${line%%=*}"
                    local sval="${line#*=}"
                    echo -e "    ${W}${sname}${NC} = ${G}${sval}${NC}"
                fi
            done
        fi
        pause_key; return
    fi

    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#profiles[@]} )); then
        echo -e "    ${R}Ungueltig.${NC}"; sleep 1; return
    fi

    local profile="${profiles[$((sel-1))]}"
    local profile_name=$(basename "$profile" .biosprofile)

    section "Profil anwenden: $profile_name"

    # BIOS Passwort abfragen falls noetig
    local bios_pw=""
    local pw_needed=false
    for f in /sys/class/firmware-attributes/*/authentication/Admin/is_enabled; do
        if [[ -f "$f" ]]; then
            local enabled=$(cat "$f" 2>/dev/null)
            [[ "$enabled" == "1" ]] && pw_needed=true
        fi
    done

    if $pw_needed; then
        echo -ne "    ${Y}BIOS Admin-Passwort erforderlich:${NC} "
        read -rs bios_pw
        echo ""
    fi

    # Settings lesen und anwenden
    local applied=0 skipped=0 failed=0

    while IFS= read -r line; do
        # Kommentare und leere Zeilen ueberspringen
        [[ "$line" == \#* || -z "$line" ]] && continue

        local setting_name="${line%%=*}"
        local setting_val="${line#*=}"

        # Pruefen ob Setting existiert
        local attr_path="${FW_ATTR_PATH}/${setting_name}"
        if [[ ! -d "$attr_path" ]]; then
            echo -e "    ${Y}[SKIP]${NC} ${setting_name} — nicht vorhanden auf diesem System"
            ((skipped++))
            continue
        fi

        # Aktuellen Wert pruefen
        local current=$(cat "$attr_path/current_value" 2>/dev/null | xargs)
        if [[ "$current" == "$setting_val" ]]; then
            echo -e "    ${DIM}[=]${NC}    ${setting_name} = ${current} (bereits korrekt)"
            ((skipped++))
            continue
        fi

        # Wert schreiben
        echo -ne "    ${C}[...]${NC}  ${setting_name}: ${current} -> ${setting_val}... "

        if [[ -n "$bios_pw" ]]; then
            # Mit Passwort
            local pw_path=""
            for pf in /sys/class/firmware-attributes/*/authentication/Admin/current_password; do
                [[ -f "$pf" ]] && pw_path="$pf" && break
            done
            [[ -n "$pw_path" ]] && echo "$bios_pw" > "$pw_path" 2>/dev/null
        fi

        if echo "$setting_val" > "$attr_path/current_value" 2>/dev/null; then
            echo -e "${G}OK${NC}"
            ((applied++))
        else
            echo -e "${R}FEHLER${NC}"
            ((failed++))
        fi

    done < "$profile"

    echo ""
    echo -e "    ${DIM}────────────────────────────────────────────────${NC}"
    result_ok "Angewendet: $applied"
    [[ $skipped -gt 0 ]] && result_info "Uebersprungen: $skipped"
    [[ $failed -gt 0 ]] && result_fail "Fehlgeschlagen: $failed"

    if (( applied > 0 )); then
        echo ""
        result_warn "BIOS Settings werden nach Neustart aktiv!"
        echo -e "    ${Y}Jetzt neustarten? [j/n]${NC}"
        echo -ne "    > "
        read -r reboot_now
        [[ "${reboot_now,,}" == "j" ]] && reboot
    fi

    pause_key
}

# ─── [8] Profil-Verwaltung ───────────────────────────────────────────────────
do_manage_profiles() {
    bios_header
    echo -e "    ${W}PROFIL-VERWALTUNG${NC}"
    echo ""

    # Alle Profile auflisten
    local profiles=()

    if [[ -d "$PROFILES_DIR" ]]; then
        while IFS= read -r f; do
            profiles+=("$f")
        done < <(find "$PROFILES_DIR" -name "*.biosprofile" -type f 2>/dev/null | sort)
    fi

    for mp in /mnt/usb* /mnt/*/  /run/media/*/*/; do
        local bdir="${mp}BIOS_Settings"
        [[ -d "$bdir" ]] && while IFS= read -r f; do
            profiles+=("$f")
        done < <(find "$bdir" -name "*.biosprofile" -type f 2>/dev/null | sort)
    done

    if [[ ${#profiles[@]} -eq 0 ]]; then
        result_info "Keine Profile vorhanden."
    else
        section "Gespeicherte Profile"
        for i in "${!profiles[@]}"; do
            local f="${profiles[$i]}"
            local name=$(basename "$f" .biosprofile)
            local loc=$(dirname "$f")
            local settings=$(grep -vc "^#\|^$" "$f" 2>/dev/null || echo "?")
            echo -e "    ${C}[$((i+1))]${NC}  ${W}${name}${NC}  ${DIM}(${settings} Settings, ${loc})${NC}"
        done
    fi

    echo ""
    echo -e "    ${C}[n]${NC}  Neues leeres Profil erstellen"
    echo -e "    ${C}[i]${NC}  Profil von USB importieren"
    echo -e "    ${C}[d]${NC}  Profil loeschen"
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo ""
    echo -ne "    Auswahl: "
    read -r sel

    case "$sel" in
        0) return ;;
        n|N)
            echo -ne "    ${W}Profilname:${NC} "
            read -r pname
            [[ -z "$pname" ]] && return
            pname=$(echo "$pname" | tr ' ' '_' | tr -cd 'A-Za-z0-9_-')
            local new_file="${PROFILES_DIR}/${pname}.biosprofile"
            mkdir -p "$PROFILES_DIR"
            {
                echo "# flowbit OS BIOS Profil"
                echo "# Name: ${pname}"
                echo "# Erstellt: $(date '+%d.%m.%Y %H:%M:%S')"
                echo "# Manuell erstellt"
                echo "#"
                echo "# Format: SettingName=Value"
                echo "# Beispiele (Dell):"
                echo "# SecureBoot=Enabled"
                echo "# TpmSecurity=Enabled"
                echo "# Virtualization=Enabled"
                echo "# WakeOnLan=LanOnly"
                echo "# UefiBootPathSecurity=AlwaysExceptInternalHdd"
                echo "#"
            } > "$new_file"
            result_ok "Leeres Profil erstellt: $new_file"
            result_info "Bearbeite die Datei auf dem USB-Stick oder mit nano"

            if find_usb_profiles; then
                cp "$new_file" "${USB_PROFILES_DIR}/${pname}.biosprofile"
                result_ok "Kopiert auf USB: ${USB_PROFILES_DIR}/${pname}.biosprofile"
            fi
            ;;
        i|I)
            echo ""
            echo -ne "    Pfad zur .biosprofile Datei: "
            read -r import_path
            if [[ -f "$import_path" ]]; then
                mkdir -p "$PROFILES_DIR"
                cp "$import_path" "$PROFILES_DIR/"
                result_ok "Importiert: $(basename "$import_path")"
            else
                result_fail "Datei nicht gefunden: $import_path"
            fi
            ;;
        d|D)
            echo -ne "    Welches Profil loeschen (Nummer)? "
            read -r dsel
            if [[ "$dsel" =~ ^[0-9]+$ ]] && (( dsel >= 1 && dsel <= ${#profiles[@]} )); then
                local del_file="${profiles[$((dsel-1))]}"
                echo -e "    ${Y}Loeschen: $(basename "$del_file")? [j/n]${NC}"
                echo -ne "    > "
                read -r confirm
                if [[ "${confirm,,}" == "j" ]]; then
                    rm -f "$del_file"
                    result_ok "Geloescht"
                fi
            fi
            ;;
    esac

    pause_key
}

# ─── [9] Komplett-Report ─────────────────────────────────────────────────────
do_full_report() {
    REPORT_DATA=""
    report_add "================================================================"
    report_add "  BIOS KOMPLETT-REPORT — flowbit OS"
    report_add "  Datum: $(date '+%d.%m.%Y %H:%M:%S')"
    report_add "  Host:  $HOSTNAME_STR"
    report_add "================================================================"

    bios_header
    echo -e "    ${W}BIOS KOMPLETT-REPORT${NC}"
    echo ""

    section "Firmware"
    result_line "BIOS Vendor:" "$(get_dmi bios-vendor)"
    result_line "BIOS Version:" "$(get_dmi bios-version)"
    result_line "BIOS Datum:" "$(get_dmi bios-release-date)"
    [[ -d /sys/firmware/efi ]] && result_line "Boot-Modus:" "UEFI" || result_line "Boot-Modus:" "Legacy"

    local sb_val=""
    for f in /sys/firmware/efi/efivars/SecureBoot-*; do
        [[ -f "$f" ]] && sb_val=$(od -An -t u1 "$f" 2>/dev/null | awk '{print $NF}') && break
    done
    [[ "$sb_val" == "1" ]] && result_line "Secure Boot:" "AN" || result_line "Secure Boot:" "AUS"

    section "TPM"
    local tpm_ver=$(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null || echo "nicht erkannt")
    result_line "TPM:" "$tpm_ver"

    section "System"
    result_line "Hersteller:" "$(get_dmi system-manufacturer)"
    result_line "Modell:" "$(get_dmi system-product-name)"
    result_line "SN:" "$(get_dmi system-serial-number)"
    result_line "UUID:" "$(get_dmi system-uuid)"
    result_line "SKU:" "$(get_dmi system-sku-number)"

    section "Mainboard"
    result_line "Hersteller:" "$(get_dmi baseboard-manufacturer)"
    result_line "Modell:" "$(get_dmi baseboard-product-name)"
    result_line "SN:" "$(get_dmi baseboard-serial-number)"
    result_line "Asset Tag:" "$(get_dmi baseboard-asset-tag)"

    section "Windows Key"
    if [[ -f /sys/firmware/acpi/tables/MSDM ]]; then
        local key=$(strings /sys/firmware/acpi/tables/MSDM 2>/dev/null | grep -oE '[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}' | head -1)
        result_line "OEM Key:" "${key:-nicht auslesbar}"
    else
        result_line "OEM Key:" "nicht vorhanden"
    fi

    if [[ -n "$FW_ATTR_PATH" ]]; then
        section "BIOS Settings (Firmware Attributes)"
        for attr_dir in "$FW_ATTR_PATH"/*/; do
            [[ ! -d "$attr_dir" ]] && continue
            local name=$(basename "$attr_dir")
            local val=$(cat "$attr_dir/current_value" 2>/dev/null | xargs)
            [[ -n "$val" ]] && report_add "  ${name} = ${val}"
        done
    fi

    echo ""
    echo -e "    ${C}[1]${NC}  Report speichern"
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo -ne "    Auswahl: "
    read -r sel
    [[ "$sel" == "1" ]] && save_report "BIOS_FULL"

    pause_key
}

# ─── Menue ────────────────────────────────────────────────────────────────────
bios_menu() {
    while true; do
        bios_header
        echo -e "    ${W}BIOS TOOLS${NC}"
        echo ""
        echo -e "    ${C}── Info ────────────────────────────────────────${NC}"
        echo -e "    ${C}[1]${NC}  BIOS/UEFI Uebersicht  ${DIM}— Firmware, System, Board${NC}"
        echo -e "    ${C}[2]${NC}  Secure Boot Status     ${DIM}— UEFI, Secure Boot, EFI Entries${NC}"
        echo -e "    ${C}[3]${NC}  TPM Status             ${DIM}— Version, Win11 Check${NC}"
        echo -e "    ${C}[4]${NC}  Asset Tag / IDs        ${DIM}— Seriennummern, Keys, Intune${NC}"
        echo ""
        echo -e "    ${C}── BIOS Settings ───────────────────────────────${NC}"
        echo -e "    ${C}[5]${NC}  Settings auslesen      ${DIM}— Alle BIOS Settings -> TXT/Profil${NC}"
        echo -e "    ${C}[6]${NC}  Profil anwenden        ${DIM}— Gespeichertes Profil laden${NC}"
        echo -e "    ${C}[7]${NC}  Profil-Verwaltung      ${DIM}— Erstellen, Importieren, Loeschen${NC}"
        echo ""
        echo -e "    ${C}[8]${NC}  Komplett-Report        ${DIM}— Alles exportieren${NC}"
        echo ""
        echo -e "    ${C}[0]${NC}  Zurueck zum Hauptmenue"
        echo ""

        # Status-Info
        if [[ -n "$FW_ATTR_PATH" ]]; then
            echo -e "    ${G}Firmware Attributes: verfuegbar${NC}"
        else
            echo -e "    ${DIM}Firmware Attributes: nicht verfuegbar (nur Info-Modus)${NC}"
        fi
        echo ""

        echo -ne "    Auswahl: "
        read -r choice

        case "$choice" in
            1) do_bios_overview ;;
            2) do_secureboot ;;
            3) do_tpm ;;
            4) do_asset_tag ;;
            5) do_read_settings ;;
            6) do_apply_profile ;;
            7) do_manage_profiles ;;
            8) do_full_report ;;
            0) return ;;
            *) echo -e "    ${R}Ungueltig.${NC}"; sleep 1 ;;
        esac
    done
}

if [[ $EUID -ne 0 ]]; then
    echo -e "${R}Fehler: Root-Rechte erforderlich.${NC}"
    exit 1
fi

mkdir -p "$PROFILES_DIR" 2>/dev/null
bios_menu
