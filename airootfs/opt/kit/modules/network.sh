#!/bin/bash
# =============================================================================
#  NETZWERK TOOLS — flowbit OS Modul | Diagnose & Export
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
LOG_DIR="/tmp/network_${TIMESTAMP}"
REPORT_DATA=""
mkdir -p "$LOG_DIR"

# ─── Hilfsfunktionen ─────────────────────────────────────────────────────────
net_header() {
    clear
    echo ""
    echo -e "${G}    ███╗   ██╗███████╗████████╗██╗    ██╗ ██████╗ ██████╗ ██╗  ██╗${NC}"
    echo -e "${G}    ████╗  ██║██╔════╝╚══██╔══╝██║    ██║██╔═══██╗██╔══██╗██║ ██╔╝${NC}"
    echo -e "${G}    ██╔██╗ ██║█████╗     ██║   ██║ █╗ ██║██║   ██║██████╔╝█████╔╝ ${NC}"
    echo -e "${G}    ██║╚██╗██║██╔══╝     ██║   ██║███╗██║██║   ██║██╔══██╗██╔═██╗ ${NC}"
    echo -e "${G}    ██║ ╚████║███████╗   ██║   ╚███╔███╔╝╚██████╔╝██║  ██║██║  ██╗${NC}"
    echo -e "${G}    ╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝${NC}"
    echo -e "${DIM}    ────────────────────────────────────────────────────────────${NC}"
    echo ""
}

pause_key() {
    echo ""
    echo -e "    ${DIM}[ Enter zum Fortfahren ]${NC}"
    read -r
}

report_add() {
    REPORT_DATA+="$1"$'\n'
}

section_header() {
    echo ""
    echo -e "    ${C}── $1 ──────────────────────────────────────────${NC}"
    echo ""
    report_add ""
    report_add "  $1"
    report_add "  ────────────────────────────────────────────────"
}

result_line() {
    local label="$1" value="$2"
    printf "    ${DIM}%-18s${NC} ${W}%s${NC}\n" "$label" "$value"
    printf "  %-18s %s\n" "$label" "$value" >> /dev/null
    report_add "  $(printf '%-18s %s' "$label" "$value")"
}

result_ok()   { echo -e "    ${G}[OK]${NC}   $1"; report_add "  [OK]   $1"; }
result_fail() { echo -e "    ${R}[FAIL]${NC} $1"; report_add "  [FAIL] $1"; }
result_info() { echo -e "    ${DIM}$1${NC}"; report_add "  $1"; }

# ─── [1] Netzwerk-Uebersicht ─────────────────────────────────────────────────
do_overview() {
    net_header
    echo -e "    ${W}NETZWERK-UEBERSICHT${NC}"
    REPORT_DATA=""
    report_add "  NETZWERK-UEBERSICHT"
    report_add "  Datum: $(date '+%d.%m.%Y %H:%M:%S')"

    section_header "Interfaces"

    for iface_path in /sys/class/net/*; do
        local iface=$(basename "$iface_path")
        [[ "$iface" == "lo" ]] && continue

        local mac=$(cat "$iface_path/address" 2>/dev/null || echo "N/A")
        local state=$(cat "$iface_path/operstate" 2>/dev/null || echo "?")
        local speed=$(cat "$iface_path/speed" 2>/dev/null || echo "?")
        local driver=$(basename "$(readlink "$iface_path/device/driver" 2>/dev/null)" 2>/dev/null || echo "?")
        local ipv4=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -1)
        local ipv6=$(ip -6 addr show "$iface" scope global 2>/dev/null | awk '/inet6 /{print $2}' | head -1)

        local state_color="${R}"
        [[ "$state" == "up" ]] && state_color="${G}"

        echo -e "    ${W}${iface}${NC}  ${state_color}${state}${NC}  ${DIM}(${driver})${NC}"
        report_add "  $iface  $state  ($driver)"
        [[ "$speed" != "?" && "$speed" -gt 0 ]] 2>/dev/null && { result_line "  Speed:" "${speed} Mbit/s"; }
        result_line "  MAC:" "$mac"
        [[ -n "$ipv4" ]] && result_line "  IPv4:" "$ipv4"
        [[ -n "$ipv6" ]] && result_line "  IPv6:" "$ipv6"
        echo ""
    done

    section_header "Routing"
    local gateway=$(ip route | awk '/default/{print $3}' | head -1)
    local gw_iface=$(ip route | awk '/default/{print $5}' | head -1)
    result_line "Gateway:" "${gateway:-keins} (${gw_iface:-?})"

    section_header "DNS"
    while IFS= read -r ns; do
        result_line "Nameserver:" "$ns"
    done < <(grep "^nameserver" /etc/resolv.conf 2>/dev/null | awk '{print $2}')
    local search=$(grep "^search" /etc/resolv.conf 2>/dev/null | awk '{$1=""; print $0}' | xargs)
    [[ -n "$search" ]] && result_line "Search Domain:" "$search"

    section_header "DHCP Lease"
    # Versuche DHCP Info aus verschiedenen Quellen
    if command -v networkctl &>/dev/null; then
        local main_if=$(ip route | awk '/default/{print $5}' | head -1)
        if [[ -n "$main_if" ]]; then
            local dhcp_server=$(networkctl status "$main_if" 2>/dev/null | grep -i "DHCP" | head -3)
            if [[ -n "$dhcp_server" ]]; then
                echo "$dhcp_server" | while IFS= read -r line; do
                    result_info "$(echo "$line" | xargs)"
                done
            else
                result_info "Keine DHCP-Infos gefunden"
            fi
        fi
    else
        result_info "networkctl nicht verfuegbar"
    fi

    pause_key
}

# ─── [2] Ping-Test ───────────────────────────────────────────────────────────
do_ping() {
    net_header
    echo -e "    ${W}PING-TEST${NC}"
    echo ""
    REPORT_DATA=""
    report_add "  PING-TEST"
    report_add "  Datum: $(date '+%d.%m.%Y %H:%M:%S')"

    echo -e "    ${C}[1]${NC}  Standard-Ziele (Gateway, DNS, Internet)"
    echo -e "    ${C}[2]${NC}  Eigenes Ziel eingeben"
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo ""
    echo -ne "    Auswahl: "
    read -r sel

    local targets=()
    case "$sel" in
        0) return ;;
        1)
            local gw=$(ip route | awk '/default/{print $3}' | head -1)
            [[ -n "$gw" ]] && targets+=("$gw|Gateway")
            targets+=("1.1.1.1|Cloudflare DNS")
            targets+=("8.8.8.8|Google DNS")
            targets+=("google.com|Google (DNS-Aufloesung)")
            targets+=("microsoft.com|Microsoft")
            ;;
        2)
            echo -ne "    Ziel (IP oder Hostname): "
            read -r custom_target
            [[ -n "$custom_target" ]] && targets+=("$custom_target|$custom_target")
            ;;
    esac

    echo ""
    section_header "Ergebnisse"

    for entry in "${targets[@]}"; do
        local target="${entry%%|*}"
        local label="${entry##*|}"

        echo -ne "    ${DIM}Ping ${label} (${target})...${NC} "

        local result
        result=$(ping -c 4 -W 3 "$target" 2>&1)
        local rc=$?

        if [[ $rc -eq 0 ]]; then
            local stats=$(echo "$result" | tail -1)
            local loss=$(echo "$result" | grep -oP '\d+% packet loss')
            local avg=$(echo "$stats" | awk -F'/' '{print $5}')
            result_ok "${label}: ${avg}ms avg, ${loss}"
        else
            result_fail "${label}: nicht erreichbar"
        fi
    done

    pause_key
}

# ─── [3] DNS Lookup ──────────────────────────────────────────────────────────
do_dns() {
    net_header
    echo -e "    ${W}DNS LOOKUP${NC}"
    echo ""
    REPORT_DATA=""
    report_add "  DNS LOOKUP"

    echo -ne "    Hostname eingeben: "
    read -r dns_target

    [[ -z "$dns_target" ]] && return

    section_header "DNS Abfrage: $dns_target"

    # A Record
    echo -e "    ${DIM}A Record:${NC}"
    if command -v dig &>/dev/null; then
        local a_result=$(dig +short A "$dns_target" 2>/dev/null)
        if [[ -n "$a_result" ]]; then
            while IFS= read -r ip; do
                result_line "  A:" "$ip"
            done <<< "$a_result"
        else
            result_info "  Kein A Record"
        fi

        # MX
        echo -e "    ${DIM}MX Record:${NC}"
        local mx_result=$(dig +short MX "$dns_target" 2>/dev/null)
        if [[ -n "$mx_result" ]]; then
            while IFS= read -r mx; do
                result_line "  MX:" "$mx"
            done <<< "$mx_result"
        else
            result_info "  Kein MX Record"
        fi

        # NS
        echo -e "    ${DIM}NS Record:${NC}"
        local ns_result=$(dig +short NS "$dns_target" 2>/dev/null)
        if [[ -n "$ns_result" ]]; then
            while IFS= read -r ns; do
                result_line "  NS:" "$ns"
            done <<< "$ns_result"
        else
            result_info "  Kein NS Record"
        fi

        # TXT (SPF, DMARC etc.)
        echo -e "    ${DIM}TXT Record:${NC}"
        local txt_result=$(dig +short TXT "$dns_target" 2>/dev/null | head -5)
        if [[ -n "$txt_result" ]]; then
            while IFS= read -r txt; do
                result_info "  $txt"
            done <<< "$txt_result"
        fi

        # Reverse DNS
        if [[ -n "$a_result" ]]; then
            local first_ip=$(echo "$a_result" | head -1)
            echo -e "    ${DIM}Reverse DNS (${first_ip}):${NC}"
            local ptr=$(dig +short -x "$first_ip" 2>/dev/null)
            result_line "  PTR:" "${ptr:-keins}"
        fi
    elif command -v nslookup &>/dev/null; then
        nslookup "$dns_target" 2>/dev/null | while IFS= read -r line; do
            result_info "$line"
        done
    else
        result_fail "Weder dig noch nslookup verfuegbar"
    fi

    pause_key
}

# ─── [4] Traceroute ──────────────────────────────────────────────────────────
do_traceroute() {
    net_header
    echo -e "    ${W}TRACEROUTE${NC}"
    echo ""
    REPORT_DATA=""
    report_add "  TRACEROUTE"

    echo -e "    ${C}[1]${NC}  google.com"
    echo -e "    ${C}[2]${NC}  cloudflare.com"
    echo -e "    ${C}[3]${NC}  Eigenes Ziel"
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo ""
    echo -ne "    Auswahl: "
    read -r sel

    local target=""
    case "$sel" in
        0) return ;;
        1) target="google.com" ;;
        2) target="cloudflare.com" ;;
        3) echo -ne "    Ziel: "; read -r target ;;
    esac

    [[ -z "$target" ]] && return

    section_header "Traceroute: $target"

    if command -v traceroute &>/dev/null; then
        timeout 15 traceroute -m 15 -w 2 "$target" 2>&1 | while IFS= read -r line; do
            echo -e "    ${DIM}${line}${NC}"
            report_add "  $line"
        done
    elif command -v tracepath &>/dev/null; then
        timeout 15 tracepath -m 15 "$target" 2>&1 | head -20 | while IFS= read -r line; do
            echo -e "    ${DIM}${line}${NC}"
            report_add "  $line"
        done
    else
        result_fail "traceroute/tracepath nicht verfuegbar"
    fi

    pause_key
}

# ─── [5] Port-Check ──────────────────────────────────────────────────────────
do_portcheck() {
    net_header
    echo -e "    ${W}PORT-CHECK${NC}"
    echo ""
    REPORT_DATA=""
    report_add "  PORT-CHECK"

    echo -e "    ${C}[1]${NC}  Standard-Ports pruefen (HTTP, HTTPS, DNS, SSH, RDP, SMB)"
    echo -e "    ${C}[2]${NC}  Eigenes Ziel + Port"
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo ""
    echo -ne "    Auswahl: "
    read -r sel

    case "$sel" in
        0) return ;;
        1)
            echo -ne "    Ziel-IP oder Hostname: "
            read -r target
            [[ -z "$target" ]] && return

            section_header "Port-Scan: $target"

            local ports=("22|SSH" "53|DNS" "80|HTTP" "443|HTTPS" "445|SMB" "3389|RDP" "5985|WinRM" "8080|HTTP-Alt")
            for entry in "${ports[@]}"; do
                local port="${entry%%|*}"
                local name="${entry##*|}"
                echo -ne "    ${DIM}${name} (${port})...${NC} "
                if (echo >/dev/tcp/"$target"/"$port") 2>/dev/null; then
                    result_ok "${name}:${port} offen"
                else
                    result_fail "${name}:${port} geschlossen/gefiltert"
                fi
            done
            ;;
        2)
            echo -ne "    Ziel-IP oder Hostname: "
            read -r target
            echo -ne "    Port: "
            read -r port
            [[ -z "$target" || -z "$port" ]] && return

            section_header "Port-Check: ${target}:${port}"
            echo -ne "    ${DIM}Pruefe ${target}:${port}...${NC} "
            if (echo >/dev/tcp/"$target"/"$port") 2>/dev/null; then
                result_ok "Port ${port} offen"
            else
                result_fail "Port ${port} geschlossen/gefiltert"
            fi
            ;;
    esac

    pause_key
}

# ─── [6] Speedtest ───────────────────────────────────────────────────────────
do_speedtest() {
    net_header
    echo -e "    ${W}SPEEDTEST${NC}"
    echo ""
    REPORT_DATA=""
    report_add "  SPEEDTEST"
    report_add "  Datum: $(date '+%d.%m.%Y %H:%M:%S')"

    section_header "Download-Test"

    # Mehrere Test-URLs (verschiedene Groessen)
    local urls=(
        "http://speedtest.tele2.net/1MB.zip|1 MB"
        "http://speedtest.tele2.net/10MB.zip|10 MB"
        "http://speedtest.tele2.net/100MB.zip|100 MB"
    )

    echo -e "    ${C}[1]${NC}  Schnell (1 MB)"
    echo -e "    ${C}[2]${NC}  Normal (10 MB)"
    echo -e "    ${C}[3]${NC}  Ausfuehrlich (100 MB)"
    echo -e "    ${C}[0]${NC}  Zurueck"
    echo ""
    echo -ne "    Auswahl: "
    read -r sel

    local url="" label=""
    case "$sel" in
        0) return ;;
        1) url="http://speedtest.tele2.net/1MB.zip"; label="1 MB" ;;
        2) url="http://speedtest.tele2.net/10MB.zip"; label="10 MB" ;;
        3) url="http://speedtest.tele2.net/100MB.zip"; label="100 MB" ;;
        *) return ;;
    esac

    echo ""
    echo -e "    ${C}[...]  Download ${label} Testdatei...${NC}"
    echo ""

    local dl_result
    dl_result=$(curl -o /dev/null -w "speed_download: %{speed_download}\ntime_total: %{time_total}\nsize_download: %{size_download}" -sL "$url" 2>&1)

    local speed_bps=$(echo "$dl_result" | awk -F': ' '/speed_download/{print $2}')
    local time_total=$(echo "$dl_result" | awk -F': ' '/time_total/{print $2}')
    local size=$(echo "$dl_result" | awk -F': ' '/size_download/{print $2}')

    # Umrechnung Bytes/s -> Mbit/s
    local speed_mbits=""
    if [[ -n "$speed_bps" ]]; then
        speed_mbits=$(awk "BEGIN{printf \"%.2f\", $speed_bps * 8 / 1000000}")
    fi

    if [[ -n "$speed_mbits" && "$speed_mbits" != "0.00" ]]; then
        result_ok "Download: ${speed_mbits} Mbit/s (${time_total}s, ${label})"
    else
        result_fail "Download fehlgeschlagen"
    fi

    # Upload-Test (kleiner POST)
    echo ""
    echo -e "    ${C}[...]  Upload-Test...${NC}"
    local up_result
    up_result=$(dd if=/dev/urandom bs=1M count=1 2>/dev/null | curl -o /dev/null -w "speed_upload: %{speed_upload}\ntime_total: %{time_total}" -sL -X POST -d @- "http://speedtest.tele2.net/upload.php" 2>&1)
    local up_speed=$(echo "$up_result" | awk -F': ' '/speed_upload/{print $2}')
    if [[ -n "$up_speed" ]]; then
        local up_mbits=$(awk "BEGIN{printf \"%.2f\", $up_speed * 8 / 1000000}")
        result_ok "Upload: ~${up_mbits} Mbit/s (1 MB Testdaten)"
    else
        result_info "Upload-Test nicht moeglich"
    fi

    # Latenz
    echo ""
    echo -e "    ${C}[...]  Latenz-Test...${NC}"
    local ping_result=$(ping -c 5 -W 3 1.1.1.1 2>/dev/null | tail -1)
    if [[ -n "$ping_result" ]]; then
        local avg=$(echo "$ping_result" | awk -F'/' '{print $5}')
        result_ok "Latenz: ${avg}ms avg (1.1.1.1)"
    fi

    pause_key
}

# ─── [7] VLAN / ARP ──────────────────────────────────────────────────────────
do_discovery() {
    net_header
    echo -e "    ${W}NETZWERK-DISCOVERY${NC}"
    echo ""
    REPORT_DATA=""
    report_add "  NETZWERK-DISCOVERY"

    section_header "ARP-Tabelle (bekannte Geraete)"
    local arp_out
    arp_out=$(ip neigh show 2>/dev/null | grep -v "FAILED")
    if [[ -n "$arp_out" ]]; then
        echo "$arp_out" | while IFS= read -r line; do
            local ip=$(echo "$line" | awk '{print $1}')
            local mac=$(echo "$line" | awk '{print $5}')
            local state=$(echo "$line" | awk '{print $NF}')
            echo -e "    ${W}${ip}${NC}  ${DIM}${mac}${NC}  ${DIM}(${state})${NC}"
            report_add "  $ip  $mac  ($state)"
        done
    else
        result_info "ARP-Tabelle leer"
    fi

    section_header "Offene Verbindungen"
    ss -tun 2>/dev/null | head -20 | while IFS= read -r line; do
        echo -e "    ${DIM}${line}${NC}"
        report_add "  $line"
    done

    section_header "Routing-Tabelle"
    ip route 2>/dev/null | while IFS= read -r line; do
        echo -e "    ${DIM}${line}${NC}"
        report_add "  $line"
    done

    pause_key
}

# ─── [8] Komplett-Diagnose ───────────────────────────────────────────────────
do_full_diag() {
    REPORT_DATA=""
    report_add "================================================================"
    report_add "  NETZWERK-DIAGNOSE — flowbit OS"
    report_add "  Datum: $(date '+%d.%m.%Y %H:%M:%S')"
    report_add "  Host:  $HOSTNAME_STR"
    report_add "================================================================"

    net_header
    echo -e "    ${W}KOMPLETT-DIAGNOSE${NC}"
    echo -e "    ${DIM}Fuehrt alle Tests durch und exportiert Ergebnis...${NC}"
    echo ""

    # Interfaces
    section_header "Interfaces"
    for iface_path in /sys/class/net/*; do
        local iface=$(basename "$iface_path")
        [[ "$iface" == "lo" ]] && continue
        local mac=$(cat "$iface_path/address" 2>/dev/null)
        local state=$(cat "$iface_path/operstate" 2>/dev/null)
        local ipv4=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -1)
        result_line "$iface:" "MAC=$mac  IP=${ipv4:-keine}  $state"
    done

    # Gateway + DNS
    section_header "Routing & DNS"
    local gw=$(ip route | awk '/default/{print $3}' | head -1)
    result_line "Gateway:" "${gw:-keins}"
    grep "^nameserver" /etc/resolv.conf 2>/dev/null | while read -r _ ns; do
        result_line "DNS:" "$ns"
    done

    # Ping-Tests
    section_header "Erreichbarkeit"
    local test_targets=("${gw:-1.1.1.1}|Gateway" "1.1.1.1|Cloudflare" "8.8.8.8|Google" "google.com|Internet")
    for entry in "${test_targets[@]}"; do
        local target="${entry%%|*}"
        local label="${entry##*|}"
        local ping_out=$(ping -c 3 -W 2 "$target" 2>&1)
        if [[ $? -eq 0 ]]; then
            local avg=$(echo "$ping_out" | tail -1 | awk -F'/' '{print $5}')
            result_ok "${label} (${target}): ${avg}ms"
        else
            result_fail "${label} (${target}): nicht erreichbar"
        fi
    done

    # DNS-Aufloesung
    section_header "DNS-Aufloesung"
    for domain in "google.com" "microsoft.com" "login.microsoftonline.com"; do
        local resolved=$(dig +short A "$domain" 2>/dev/null | head -1)
        if [[ -n "$resolved" ]]; then
            result_ok "${domain} -> ${resolved}"
        else
            result_fail "${domain}: Aufloesung fehlgeschlagen"
        fi
    done

    # Speed (schnell)
    section_header "Download-Speed (1 MB)"
    local speed_bps=$(curl -o /dev/null -w "%{speed_download}" -sL "http://speedtest.tele2.net/1MB.zip" 2>/dev/null)
    if [[ -n "$speed_bps" ]]; then
        local speed_mbits=$(awk "BEGIN{printf \"%.2f\", $speed_bps * 8 / 1000000}")
        result_ok "Download: ${speed_mbits} Mbit/s"
    else
        result_fail "Speedtest fehlgeschlagen"
    fi

    # ARP
    section_header "ARP-Tabelle"
    ip neigh show 2>/dev/null | grep -v "FAILED" | while IFS= read -r line; do
        result_info "$line"
    done

    report_add ""
    report_add "================================================================"
    report_add "  Erstellt mit flowbit OS Netzwerk"
    report_add "================================================================"

    echo ""
    echo -e "    ${G}Diagnose abgeschlossen.${NC}"
    echo ""
    echo -e "    ${C}[1]${NC}  Ergebnis als Datei speichern"
    echo -e "    ${C}[0]${NC}  Zurueck (nicht speichern)"
    echo ""
    echo -ne "    Auswahl: "
    read -r sel

    [[ "$sel" == "1" ]] && save_report "NETZDIAG"

    pause_key
}

# ─── Export ───────────────────────────────────────────────────────────────────
save_report() {
    local prefix="${1:-NETWORK}"
    local filename="${prefix}_${HOSTNAME_STR}_${TIMESTAMP}.txt"

    echo "$REPORT_DATA" > "/tmp/$filename"

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
network_menu() {
    while true; do
        net_header
        echo -e "    ${W}NETZWERK TOOLS${NC}"
        echo ""
        echo -e "    ${C}[1]${NC}  Netzwerk-Uebersicht   ${DIM}— Interfaces, IPs, Gateway, DNS${NC}"
        echo -e "    ${C}[2]${NC}  Ping-Test              ${DIM}— Erreichbarkeit pruefen${NC}"
        echo -e "    ${C}[3]${NC}  DNS Lookup             ${DIM}— A, MX, NS, TXT, PTR${NC}"
        echo -e "    ${C}[4]${NC}  Traceroute             ${DIM}— Route zum Ziel verfolgen${NC}"
        echo -e "    ${C}[5]${NC}  Port-Check             ${DIM}— Offene Ports pruefen${NC}"
        echo -e "    ${C}[6]${NC}  Speedtest              ${DIM}— Download/Upload/Latenz${NC}"
        echo -e "    ${C}[7]${NC}  Discovery              ${DIM}— ARP, Verbindungen, Routing${NC}"
        echo ""
        echo -e "    ${C}[8]${NC}  Komplett-Diagnose      ${DIM}— Alles testen + exportieren${NC}"
        echo ""
        echo -e "    ${C}[0]${NC}  Zurueck zum Hauptmenue"
        echo ""
        echo -ne "    Auswahl: "
        read -r choice

        case "$choice" in
            1) do_overview ;;
            2) do_ping ;;
            3) do_dns ;;
            4) do_traceroute ;;
            5) do_portcheck ;;
            6) do_speedtest ;;
            7) do_discovery ;;
            8) do_full_diag ;;
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

network_menu
