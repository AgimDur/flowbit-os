#!/bin/bash
# =============================================================================
#  BACKUP / RESTORE — flowbit OS Modul | Disk-Image, Dateien, Netzwerk
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
REPORT_DATA=""

# ─── Hilfsfunktionen ─────────────────────────────────────────────────────────
backup_header() {
    clear
    echo ""
    echo -e "${G}    ██████╗  █████╗  ██████╗██╗  ██╗██╗   ██╗██████╗ ${NC}"
    echo -e "${G}    ██╔══██╗██╔══██╗██╔════╝██║ ██╔╝██║   ██║██╔══██╗${NC}"
    echo -e "${G}    ██████╔╝███████║██║     █████╔╝ ██║   ██║██████╔╝${NC}"
    echo -e "${G}    ██╔══██╗██╔══██║██║     ██╔═██╗ ██║   ██║██╔═══╝ ${NC}"
    echo -e "${G}    ██████╔╝██║  ██║╚██████╗██║  ██╗╚██████╔╝██║     ${NC}"
    echo -e "${G}    ╚═════╝ ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝     ${NC}"
    echo -e "${DIM}    ──────────────────────────────────────────────────${NC}"
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
}

# ─── Ziel-Auswahl (USB / Netzwerk / Lokal) ───────────────────────────────────
BACKUP_TARGET=""
BACKUP_TARGET_LABEL=""
NFS_MOUNTED=false
SMB_MOUNTED=false
SSH_TARGET=""
MOUNT_POINT="/mnt/backup_target"

select_target() {
    backup_header
    echo -e "    ${W}BACKUP-ZIEL WAEHLEN${NC}"
    echo ""
    
    # USB-Sticks suchen
    local usb_paths=()
    local usb_labels=()
    for mp in /mnt/usb* /mnt/*/  /run/media/*/*/; do
        if [[ -d "$mp" && -w "$mp" ]]; then
            local avail=$(df -h "$mp" 2>/dev/null | awk 'NR==2{print $4}')
            usb_paths+=("$mp")
            usb_labels+=("USB: $mp (${avail:-?} frei)")
        fi
    done

    local idx=1
    echo -e "    ${C}── USB ─────────────────────────────────────────${NC}"
    if [[ ${#usb_paths[@]} -gt 0 ]]; then
        for i in "${!usb_paths[@]}"; do
            echo -e "    ${C}[${idx}]${NC}  ${usb_labels[$i]}"
            ((idx++))
        done
    else
        echo -e "    ${DIM}    Kein USB-Stick gefunden${NC}"
    fi

    echo ""
    echo -e "    ${C}── Netzwerk ────────────────────────────────────${NC}"
    echo -e "    ${C}[n]${NC}  NFS Share (Linux/NAS)"
    echo -e "    ${C}[s]${NC}  SMB/CIFS Share (Windows/NAS)"
    echo -e "    ${C}[c]${NC}  SSH/SCP (Remote Server)"
    echo ""
    echo -e "    ${C}── Lokal ───────────────────────────────────────${NC}"
    echo -e "    ${C}[l]${NC}  Lokaler Pfad (andere Partition/Disk)"
    echo ""
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo ""
    echo -ne "    Auswahl: "
    read -r sel

    case "$sel" in
        0) return 1 ;;
        [0-9]*)
            if (( sel >= 1 && sel <= ${#usb_paths[@]} )); then
                BACKUP_TARGET="${usb_paths[$((sel-1))]}"
                BACKUP_TARGET_LABEL="USB: $BACKUP_TARGET"
                return 0
            fi
            echo -e "    ${R}Ungueltig.${NC}"; sleep 1; return 1 ;;
        n|N)
            echo ""
            echo -ne "    NFS Server (z.B. 10.11.10.50:/backup): "
            read -r nfs_path
            [[ -z "$nfs_path" ]] && return 1
            mkdir -p "$MOUNT_POINT"
            echo -e "    ${C}[...]  Mounte NFS...${NC}"
            if mount -t nfs "$nfs_path" "$MOUNT_POINT" 2>/dev/null; then
                BACKUP_TARGET="$MOUNT_POINT"
                BACKUP_TARGET_LABEL="NFS: $nfs_path"
                NFS_MOUNTED=true
                result_ok "NFS gemountet: $nfs_path"
                return 0
            else
                result_fail "NFS Mount fehlgeschlagen"
                return 1
            fi ;;
        s|S)
            echo ""
            echo -ne "    SMB Share (z.B. //server/share): "
            read -r smb_path
            [[ -z "$smb_path" ]] && return 1
            echo -ne "    Benutzername (leer=guest): "
            read -r smb_user
            echo -ne "    Passwort: "
            read -rs smb_pass
            echo ""
            mkdir -p "$MOUNT_POINT"
            echo -e "    ${C}[...]  Mounte SMB...${NC}"
            local mount_opts="guest"
            [[ -n "$smb_user" ]] && mount_opts="username=${smb_user},password=${smb_pass}"
            if mount -t cifs "$smb_path" "$MOUNT_POINT" -o "$mount_opts" 2>/dev/null; then
                BACKUP_TARGET="$MOUNT_POINT"
                BACKUP_TARGET_LABEL="SMB: $smb_path"
                SMB_MOUNTED=true
                result_ok "SMB gemountet: $smb_path"
                return 0
            else
                result_fail "SMB Mount fehlgeschlagen"
                result_info "Tipp: Pruefen ob cifs-utils installiert ist"
                return 1
            fi ;;
        c|C)
            echo ""
            echo -ne "    SSH Ziel (z.B. user@server:/backup): "
            read -r ssh_path
            [[ -z "$ssh_path" ]] && return 1
            # Test SSH Verbindung
            local ssh_host="${ssh_path%%:*}"
            echo -e "    ${C}[...]  Teste SSH Verbindung...${NC}"
            if ssh -o ConnectTimeout=5 -o BatchMode=yes "$ssh_host" "echo ok" 2>/dev/null; then
                SSH_TARGET="$ssh_path"
                BACKUP_TARGET="SSH"
                BACKUP_TARGET_LABEL="SSH: $ssh_path"
                result_ok "SSH erreichbar"
                return 0
            else
                result_warn "SSH Key-Auth fehlgeschlagen, versuche mit Passwort..."
                SSH_TARGET="$ssh_path"
                BACKUP_TARGET="SSH"
                BACKUP_TARGET_LABEL="SSH: $ssh_path"
                return 0
            fi ;;
        l|L)
            echo ""
            echo -ne "    Lokaler Pfad (z.B. /mnt/data): "
            read -r local_path
            if [[ -d "$local_path" && -w "$local_path" ]]; then
                BACKUP_TARGET="$local_path"
                BACKUP_TARGET_LABEL="Lokal: $local_path"
                return 0
            else
                result_fail "Pfad nicht beschreibbar: $local_path"
                return 1
            fi ;;
        *) echo -e "    ${R}Ungueltig.${NC}"; sleep 1; return 1 ;;
    esac
}

cleanup_mounts() {
    $NFS_MOUNTED && umount "$MOUNT_POINT" 2>/dev/null && NFS_MOUNTED=false
    $SMB_MOUNTED && umount "$MOUNT_POINT" 2>/dev/null && SMB_MOUNTED=false
}

# ─── Disk/Partition Auswahl ───────────────────────────────────────────────────
select_source_disk() {
    echo -e "    ${W}Quelle waehlen:${NC}"
    echo ""

    local items=()
    # Ganze Disks
    while IFS= read -r line; do
        local name=$(echo "$line" | awk '{print $1}')
        local size=$(lsblk -d -n -o SIZE /dev/"$name" 2>/dev/null | xargs)
        local model=$(lsblk -d -n -o MODEL /dev/"$name" 2>/dev/null | xargs)
        items+=("/dev/$name|Disk: $name ($size, $model)")
    done < <(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2=="disk"' | grep -E "^(sd|nvme|hd|vd)")

    # Partitionen
    while IFS= read -r line; do
        local name=$(echo "$line" | awk '{print $1}')
        local size=$(echo "$line" | awk '{print $4}')
        local fstype=$(lsblk -n -o FSTYPE /dev/"$name" 2>/dev/null | xargs)
        local mp=$(lsblk -n -o MOUNTPOINT /dev/"$name" 2>/dev/null | xargs)
        items+=("/dev/$name|Part: $name ($size, ${fstype:-?}, mount: ${mp:-keine})")
    done < <(lsblk -n -o NAME,TYPE,ROTA,SIZE 2>/dev/null | awk '$2=="part"' | grep -E "^(sd|nvme|hd|vd)")

    if [[ ${#items[@]} -eq 0 ]]; then
        echo -e "    ${R}Keine Quellen gefunden.${NC}"
        return 1
    fi

    for i in "${!items[@]}"; do
        local label="${items[$i]##*|}"
        echo -e "    ${C}[$((i+1))]${NC}  $label"
    done
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo ""
    echo -ne "    Auswahl: "
    read -r sel

    [[ "$sel" == "0" ]] && return 1
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#items[@]} )); then
        SELECTED_SOURCE="${items[$((sel-1))]%%|*}"
        return 0
    fi
    echo -e "    ${R}Ungueltig.${NC}"; return 1
}

# ─── [1] Disk/Partition Backup (Image) ───────────────────────────────────────
do_disk_backup() {
    backup_header
    echo -e "    ${W}DISK / PARTITION BACKUP${NC}"
    echo -e "    ${DIM}Erstellt ein komprimiertes Image einer ganzen Disk oder Partition.${NC}"
    echo ""

    select_target || return

    echo ""
    select_source_disk || return

    local source="$SELECTED_SOURCE"
    local source_name=$(basename "$source")
    local source_size=$(lsblk -d -n -o SIZE "$source" 2>/dev/null | xargs)
    local serial=$(cat /sys/class/dmi/id/product_serial 2>/dev/null | xargs || echo "NA")
    local imgname="IMG_${source_name}_${serial}_${TIMESTAMP}.img.zst"

    section "Backup-Details"
    echo -e "    ${W}Quelle:${NC}  $source ($source_size)"
    echo -e "    ${W}Ziel:${NC}    ${BACKUP_TARGET_LABEL}"
    echo -e "    ${W}Datei:${NC}   $imgname"
    echo -e "    ${W}Format:${NC}  zstd komprimiert"
    echo ""

    echo -e "    ${Y}Starten? [ja/nein]${NC}"
    echo -ne "    > "
    read -r confirm
    [[ "${confirm,,}" != "ja" ]] && { cleanup_mounts; return; }

    echo ""
    echo -e "    ${C}[...]  Backup laeuft...${NC}"
    echo ""

    local dest_file=""
    if [[ "$BACKUP_TARGET" == "SSH" ]]; then
        # SSH: streame direkt
        local ssh_host="${SSH_TARGET%%:*}"
        local ssh_dir="${SSH_TARGET#*:}"
        if dd if="$source" bs=4M status=progress 2>/dev/null | zstd -3 -T0 | ssh "$ssh_host" "cat > ${ssh_dir}/${imgname}" 2>/dev/null; then
            result_ok "Backup via SSH abgeschlossen: ${imgname}"
        else
            result_fail "Backup via SSH fehlgeschlagen"
        fi
    else
        dest_file="${BACKUP_TARGET}/${imgname}"
        if dd if="$source" bs=4M status=progress 2>/dev/null | pv -s "$(blockdev --getsize64 "$source" 2>/dev/null || echo 0)" 2>/dev/null | zstd -3 -T0 > "$dest_file" 2>/dev/null; then
            local fsize=$(du -h "$dest_file" 2>/dev/null | awk '{print $1}')
            result_ok "Backup abgeschlossen: ${imgname} (${fsize})"

            # Checksumme
            echo -e "    ${C}[...]  Erstelle Checksumme...${NC}"
            sha256sum "$dest_file" > "${dest_file}.sha256" 2>/dev/null
            result_ok "SHA256 gespeichert: ${imgname}.sha256"
        else
            result_fail "Backup fehlgeschlagen"
        fi
    fi

    cleanup_mounts
    pause_key
}

# ─── [2] Disk/Partition Restore ──────────────────────────────────────────────
do_disk_restore() {
    backup_header
    echo -e "    ${W}DISK / PARTITION RESTORE${NC}"
    echo -e "    ${R}ACHTUNG: Ueberschreibt das Ziel komplett!${NC}"
    echo ""

    # Image-Quelle waehlen
    echo -e "    ${W}Image-Quelle waehlen:${NC}"
    echo ""
    echo -e "    ${C}[1]${NC}  USB / lokaler Pfad"
    echo -e "    ${C}[2]${NC}  NFS Share"
    echo -e "    ${C}[3]${NC}  SMB Share"
    echo -e "    ${C}[4]${NC}  SSH"
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo ""
    echo -ne "    Auswahl: "
    read -r sel

    local image_dir=""
    case "$sel" in
        0) return ;;
        1)
            echo -ne "    Pfad zum Ordner mit Images: "
            read -r image_dir
            ;;
        2)
            echo -ne "    NFS Share (z.B. 10.11.10.50:/backup): "
            read -r nfs_path
            mkdir -p "$MOUNT_POINT"
            mount -t nfs "$nfs_path" "$MOUNT_POINT" 2>/dev/null || { result_fail "NFS Mount fehlgeschlagen"; pause_key; return; }
            image_dir="$MOUNT_POINT"
            NFS_MOUNTED=true
            ;;
        3)
            echo -ne "    SMB Share (z.B. //server/share): "
            read -r smb_path
            echo -ne "    Benutzername (leer=guest): "
            read -r smb_user
            echo -ne "    Passwort: "
            read -rs smb_pass; echo ""
            mkdir -p "$MOUNT_POINT"
            local opts="guest"
            [[ -n "$smb_user" ]] && opts="username=${smb_user},password=${smb_pass}"
            mount -t cifs "$smb_path" "$MOUNT_POINT" -o "$opts" 2>/dev/null || { result_fail "SMB Mount fehlgeschlagen"; pause_key; return; }
            image_dir="$MOUNT_POINT"
            SMB_MOUNTED=true
            ;;
        4)
            echo -ne "    SSH Quelle (z.B. user@server:/backup/image.img.zst): "
            read -r ssh_source
            # SSH restore wird separat behandelt
            echo ""
            echo -e "    ${W}Ziel-Disk waehlen:${NC}"
            select_source_disk || { cleanup_mounts; return; }
            local target="$SELECTED_SOURCE"
            echo ""
            echo -e "    ${R}ACHTUNG: Alle Daten auf ${target} werden ueberschrieben!${NC}"
            echo -ne "    ${Y}Bestaetigen? [ja/nein]:${NC} "
            read -r confirm
            [[ "${confirm,,}" != "ja" ]] && { cleanup_mounts; return; }
            local ssh_host="${ssh_source%%:*}"
            local ssh_file="${ssh_source#*:}"
            echo -e "    ${C}[...]  Restore via SSH...${NC}"
            if ssh "$ssh_host" "cat ${ssh_file}" 2>/dev/null | zstd -d | dd of="$target" bs=4M status=progress 2>/dev/null; then
                result_ok "Restore abgeschlossen"
            else
                result_fail "Restore fehlgeschlagen"
            fi
            cleanup_mounts; pause_key; return
            ;;
    esac

    [[ -z "$image_dir" || ! -d "$image_dir" ]] && { result_fail "Verzeichnis nicht gefunden"; cleanup_mounts; pause_key; return; }

    # Images auflisten
    section "Verfuegbare Images"
    local images=()
    while IFS= read -r f; do
        [[ -f "$f" ]] && images+=("$f")
    done < <(find "$image_dir" -maxdepth 2 -name "*.img.zst" -o -name "*.img.gz" -o -name "*.img" 2>/dev/null | sort)

    if [[ ${#images[@]} -eq 0 ]]; then
        result_warn "Keine Images gefunden in: $image_dir"
        cleanup_mounts; pause_key; return
    fi

    for i in "${!images[@]}"; do
        local fname=$(basename "${images[$i]}")
        local fsize=$(du -h "${images[$i]}" 2>/dev/null | awk '{print $1}')
        local fdate=$(stat -c '%y' "${images[$i]}" 2>/dev/null | cut -d. -f1)
        echo -e "    ${C}[$((i+1))]${NC}  ${W}${fname}${NC}  ${DIM}(${fsize}, ${fdate})${NC}"
    done
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo ""
    echo -ne "    Image waehlen: "
    read -r sel

    [[ "$sel" == "0" ]] && { cleanup_mounts; return; }
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#images[@]} )); then
        echo -e "    ${R}Ungueltig.${NC}"; cleanup_mounts; pause_key; return
    fi

    local image_file="${images[$((sel-1))]}"

    # Checksumme pruefen falls vorhanden
    if [[ -f "${image_file}.sha256" ]]; then
        echo -e "    ${C}[...]  Pruefe Checksumme...${NC}"
        if sha256sum -c "${image_file}.sha256" 2>/dev/null | grep -q "OK"; then
            result_ok "Checksumme OK"
        else
            result_warn "Checksumme stimmt NICHT — Image moeglicherweise beschaedigt"
            echo -ne "    ${Y}Trotzdem fortfahren? [ja/nein]:${NC} "
            read -r cont
            [[ "${cont,,}" != "ja" ]] && { cleanup_mounts; return; }
        fi
    fi

    # Ziel waehlen
    echo ""
    echo -e "    ${W}Ziel-Disk/Partition waehlen:${NC}"
    echo ""
    select_source_disk || { cleanup_mounts; return; }
    local target="$SELECTED_SOURCE"

    echo ""
    echo -e "    ${W}Image:${NC}  $(basename "$image_file")"
    echo -e "    ${W}Ziel:${NC}   $target"
    echo ""
    echo -e "    ${R}ACHTUNG: Alle Daten auf ${target} werden UNWIDERRUFLICH ueberschrieben!${NC}"
    echo -ne "    ${Y}Bestaetigen? [ja/nein]:${NC} "
    read -r confirm
    [[ "${confirm,,}" != "ja" ]] && { cleanup_mounts; return; }

    echo ""
    echo -e "    ${C}[...]  Restore laeuft...${NC}"

    local decomp="cat"
    [[ "$image_file" == *.zst ]] && decomp="zstd -d"
    [[ "$image_file" == *.gz ]] && decomp="gzip -d"

    if $decomp < "$image_file" | dd of="$target" bs=4M status=progress 2>/dev/null; then
        sync
        result_ok "Restore abgeschlossen: $(basename "$image_file") -> $target"
    else
        result_fail "Restore fehlgeschlagen"
    fi

    cleanup_mounts
    pause_key
}

# ─── [3] Disk Klon ───────────────────────────────────────────────────────────
do_disk_clone() {
    backup_header
    echo -e "    ${W}DISK KLONEN (1:1 Kopie)${NC}"
    echo -e "    ${R}Ziel-Disk wird komplett ueberschrieben!${NC}"
    echo ""

    echo -e "    ${W}Quell-Disk:${NC}"
    select_source_disk || return
    local source="$SELECTED_SOURCE"

    echo ""
    echo -e "    ${W}Ziel-Disk:${NC}"
    select_source_disk || return
    local target="$SELECTED_SOURCE"

    if [[ "$source" == "$target" ]]; then
        result_fail "Quelle und Ziel sind identisch!"
        pause_key; return
    fi

    local source_size=$(lsblk -d -n -o SIZE "$source" 2>/dev/null | xargs)
    local target_size=$(lsblk -d -n -o SIZE "$target" 2>/dev/null | xargs)

    section "Klon-Details"
    echo -e "    ${W}Quelle:${NC} $source ($source_size)"
    echo -e "    ${W}Ziel:${NC}   $target ($target_size)"
    echo ""
    echo -e "    ${R}ACHTUNG: Alle Daten auf ${target} werden UNWIDERRUFLICH ueberschrieben!${NC}"
    echo -ne "    ${Y}Bestaetigen? [ja/nein]:${NC} "
    read -r confirm
    [[ "${confirm,,}" != "ja" ]] && return

    echo ""
    echo -e "    ${C}[...]  Klone $source -> $target ...${NC}"
    echo ""

    local source_bytes=$(blockdev --getsize64 "$source" 2>/dev/null || echo 0)
    if dd if="$source" of="$target" bs=4M status=progress conv=fsync 2>/dev/null; then
        sync
        result_ok "Klon abgeschlossen: $source -> $target"
    else
        result_fail "Klon fehlgeschlagen"
    fi

    pause_key
}

# ─── [4] Ordner/Dateien Backup ───────────────────────────────────────────────
do_file_backup() {
    backup_header
    echo -e "    ${W}ORDNER / DATEIEN BACKUP${NC}"
    echo -e "    ${DIM}Sichert einzelne Ordner oder Dateien als tar.zst Archiv.${NC}"
    echo ""

    # Zuerst: Was sichern?
    echo -e "    ${W}Was sichern?${NC}"
    echo ""
    echo -e "    ${C}[1]${NC}  Partition mounten und Ordner waehlen"
    echo -e "    ${C}[2]${NC}  Pfad direkt eingeben"
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo ""
    echo -ne "    Auswahl: "
    read -r sel

    local source_path=""
    case "$sel" in
        0) return ;;
        1)
            # Partitionen anzeigen zum Mounten
            echo ""
            echo -e "    ${W}Partition zum Mounten:${NC}"
            local parts=()
            while IFS= read -r line; do
                local name=$(echo "$line" | awk '{print $1}')
                local size=$(echo "$line" | awk '{print $4}')
                local fs=$(lsblk -n -o FSTYPE /dev/"$name" 2>/dev/null | xargs)
                local mp=$(lsblk -n -o MOUNTPOINT /dev/"$name" 2>/dev/null | xargs)
                parts+=("/dev/$name")
                local mounted_str="${DIM}(nicht gemountet)${NC}"
                [[ -n "$mp" ]] && mounted_str="${G}-> $mp${NC}"
                echo -e "    ${C}[${#parts[@]}]${NC}  /dev/${W}${name}${NC}  ${Y}${size}${NC}  ${DIM}${fs:-?}${NC}  ${mounted_str}"
            done < <(lsblk -n -o NAME,TYPE,ROTA,SIZE 2>/dev/null | awk '$2=="part"' | grep -E "^(sd|nvme|hd|vd)")

            echo ""
            echo -ne "    Partition: "
            read -r psel
            if [[ "$psel" =~ ^[0-9]+$ ]] && (( psel >= 1 && psel <= ${#parts[@]} )); then
                local part="${parts[$((psel-1))]}"
                local existing_mp=$(lsblk -n -o MOUNTPOINT "$part" 2>/dev/null | xargs)
                if [[ -z "$existing_mp" ]]; then
                    local tmp_mp="/mnt/backup_source_$$"
                    mkdir -p "$tmp_mp"
                    mount "$part" "$tmp_mp" 2>/dev/null || { result_fail "Mount fehlgeschlagen"; pause_key; return; }
                    result_ok "Gemountet: $part -> $tmp_mp"
                    source_path="$tmp_mp"
                else
                    source_path="$existing_mp"
                fi
            else
                echo -e "    ${R}Ungueltig.${NC}"; pause_key; return
            fi

            # Ordner auf der Partition anzeigen
            echo ""
            echo -e "    ${W}Inhalt von ${source_path}:${NC}"
            ls -la "$source_path" 2>/dev/null | head -20 | while IFS= read -r line; do
                echo -e "    ${DIM}${line}${NC}"
            done
            echo ""
            echo -ne "    Unterordner (leer = alles): "
            read -r subdir
            [[ -n "$subdir" ]] && source_path="${source_path}/${subdir}"
            ;;
        2)
            echo -ne "    Pfad eingeben: "
            read -r source_path
            ;;
    esac

    if [[ ! -e "$source_path" ]]; then
        result_fail "Pfad existiert nicht: $source_path"
        pause_key; return
    fi

    # Ziel waehlen
    echo ""
    select_target || return

    local source_name=$(basename "$source_path")
    local serial=$(cat /sys/class/dmi/id/product_serial 2>/dev/null | xargs || echo "NA")
    local archive_name="FILES_${source_name}_${serial}_${TIMESTAMP}.tar.zst"

    section "Backup-Details"
    echo -e "    ${W}Quelle:${NC}  $source_path"
    echo -e "    ${W}Ziel:${NC}    ${BACKUP_TARGET_LABEL}"
    echo -e "    ${W}Archiv:${NC}  $archive_name"
    echo ""

    local source_size=$(du -sh "$source_path" 2>/dev/null | awk '{print $1}')
    echo -e "    ${DIM}Groesse: ~${source_size}${NC}"
    echo ""
    echo -ne "    ${Y}Starten? [ja/nein]:${NC} "
    read -r confirm
    [[ "${confirm,,}" != "ja" ]] && { cleanup_mounts; return; }

    echo ""
    echo -e "    ${C}[...]  Backup laeuft...${NC}"

    if [[ "$BACKUP_TARGET" == "SSH" ]]; then
        local ssh_host="${SSH_TARGET%%:*}"
        local ssh_dir="${SSH_TARGET#*:}"
        if tar cf - -C "$(dirname "$source_path")" "$(basename "$source_path")" 2>/dev/null | zstd -3 -T0 | ssh "$ssh_host" "cat > ${ssh_dir}/${archive_name}" 2>/dev/null; then
            result_ok "Datei-Backup via SSH abgeschlossen"
        else
            result_fail "Datei-Backup via SSH fehlgeschlagen"
        fi
    else
        local dest_file="${BACKUP_TARGET}/${archive_name}"
        if tar cf - -C "$(dirname "$source_path")" "$(basename "$source_path")" 2>/dev/null | pv 2>/dev/null | zstd -3 -T0 > "$dest_file" 2>/dev/null; then
            local fsize=$(du -h "$dest_file" 2>/dev/null | awk '{print $1}')
            result_ok "Backup abgeschlossen: ${archive_name} (${fsize})"
            sha256sum "$dest_file" > "${dest_file}.sha256" 2>/dev/null
            result_ok "SHA256 gespeichert"
        else
            result_fail "Backup fehlgeschlagen"
        fi
    fi

    cleanup_mounts
    pause_key
}

# ─── [5] Ordner/Dateien Restore ──────────────────────────────────────────────
do_file_restore() {
    backup_header
    echo -e "    ${W}ORDNER / DATEIEN RESTORE${NC}"
    echo ""

    echo -e "    ${W}Archiv-Quelle:${NC}"
    echo -e "    ${C}[1]${NC}  USB / lokaler Pfad"
    echo -e "    ${C}[2]${NC}  NFS Share"
    echo -e "    ${C}[3]${NC}  SMB Share"
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo ""
    echo -ne "    Auswahl: "
    read -r sel

    local archive_dir=""
    case "$sel" in
        0) return ;;
        1) echo -ne "    Pfad: "; read -r archive_dir ;;
        2)
            echo -ne "    NFS Share: "; read -r nfs_path
            mkdir -p "$MOUNT_POINT"
            mount -t nfs "$nfs_path" "$MOUNT_POINT" 2>/dev/null || { result_fail "Mount fehlgeschlagen"; pause_key; return; }
            archive_dir="$MOUNT_POINT"; NFS_MOUNTED=true ;;
        3)
            echo -ne "    SMB Share: "; read -r smb_path
            echo -ne "    User (leer=guest): "; read -r smb_user
            echo -ne "    Passwort: "; read -rs smb_pass; echo ""
            mkdir -p "$MOUNT_POINT"
            local opts="guest"; [[ -n "$smb_user" ]] && opts="username=${smb_user},password=${smb_pass}"
            mount -t cifs "$smb_path" "$MOUNT_POINT" -o "$opts" 2>/dev/null || { result_fail "Mount fehlgeschlagen"; pause_key; return; }
            archive_dir="$MOUNT_POINT"; SMB_MOUNTED=true ;;
    esac

    [[ -z "$archive_dir" || ! -d "$archive_dir" ]] && { result_fail "Nicht gefunden"; cleanup_mounts; pause_key; return; }

    # Archive auflisten
    section "Verfuegbare Archive"
    local archives=()
    while IFS= read -r f; do
        [[ -f "$f" ]] && archives+=("$f")
    done < <(find "$archive_dir" -maxdepth 2 -name "FILES_*.tar.zst" -o -name "FILES_*.tar.gz" -o -name "*.tar.zst" -o -name "*.tar.gz" 2>/dev/null | sort)

    if [[ ${#archives[@]} -eq 0 ]]; then
        result_warn "Keine Archive gefunden"
        cleanup_mounts; pause_key; return
    fi

    for i in "${!archives[@]}"; do
        local fname=$(basename "${archives[$i]}")
        local fsize=$(du -h "${archives[$i]}" 2>/dev/null | awk '{print $1}')
        echo -e "    ${C}[$((i+1))]${NC}  ${W}${fname}${NC}  ${DIM}(${fsize})${NC}"
    done
    echo -ne "    Archiv waehlen: "
    read -r sel

    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#archives[@]} )); then
        cleanup_mounts; return
    fi
    local archive="${archives[$((sel-1))]}"

    echo -ne "    Ziel-Pfad (wohin entpacken): "
    read -r restore_path
    mkdir -p "$restore_path" 2>/dev/null

    echo ""
    echo -e "    ${C}[...]  Entpacke $(basename "$archive") -> $restore_path ...${NC}"

    local decomp="cat"
    [[ "$archive" == *.zst ]] && decomp="zstd -d"
    [[ "$archive" == *.gz ]] && decomp="gzip -d"

    if $decomp < "$archive" | tar xf - -C "$restore_path" 2>/dev/null; then
        result_ok "Restore abgeschlossen: -> $restore_path"
    else
        result_fail "Restore fehlgeschlagen"
    fi

    cleanup_mounts
    pause_key
}

# ─── Menue ────────────────────────────────────────────────────────────────────
backup_menu() {
    while true; do
        backup_header
        echo -e "    ${W}BACKUP / RESTORE${NC}"
        echo ""
        echo -e "    ${C}── Disk-Images ─────────────────────────────────${NC}"
        echo -e "    ${C}[1]${NC}  Disk/Partition Backup   ${DIM}— Komprimiertes Image erstellen${NC}"
        echo -e "    ${C}[2]${NC}  Disk/Partition Restore  ${DIM}— Image zurueckschreiben${NC}"
        echo -e "    ${C}[3]${NC}  Disk Klonen             ${DIM}— 1:1 Kopie Disk -> Disk${NC}"
        echo ""
        echo -e "    ${C}── Dateien / Ordner ────────────────────────────${NC}"
        echo -e "    ${C}[4]${NC}  Ordner/Dateien Backup   ${DIM}— Archiv erstellen (tar.zst)${NC}"
        echo -e "    ${C}[5]${NC}  Ordner/Dateien Restore  ${DIM}— Archiv entpacken${NC}"
        echo ""
        echo -e "    ${DIM}    Ziele: USB, NFS, SMB/CIFS, SSH, Lokal${NC}"
        echo ""
        echo -e "    ${C}[0]${NC}  Zurueck zum Hauptmenue"
        echo ""
        echo -ne "    Auswahl: "
        read -r choice

        case "$choice" in
            1) do_disk_backup ;;
            2) do_disk_restore ;;
            3) do_disk_clone ;;
            4) do_file_backup ;;
            5) do_file_restore ;;
            0) cleanup_mounts; return ;;
            *) echo -e "    ${R}Ungueltig.${NC}"; sleep 1 ;;
        esac
    done
}

# ─── Entry Point ─────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${R}Fehler: Root-Rechte erforderlich.${NC}"
    exit 1
fi

backup_menu
