#!/bin/bash
# KIT - flowbit OS

# Farben
RED="\e[1;31m"
CYAN="\e[1;36m"
WHITE="\e[1;37m"
GRAY="\e[0;37m"
GREEN="\e[1;32m"
YELLOW="\e[1;33m"
DIM="\e[2m"
RESET="\e[0m"

KIT_VERSION=$(cat /etc/flowbit-release 2>/dev/null || echo "5.0.0")
MODULES_DIR="/opt/kit/modules"

clear_screen() {
    clear
}

show_header() {
    echo ""
    echo -e "${RED}    ██╗████████╗   ████████╗ ██████╗  ██████╗ ██╗     ███████╗${RESET}"
    echo -e "${RED}    ██║╚══██╔══╝   ╚══██╔══╝██╔═══██╗██╔═══██╗██║     ██╔════╝${RESET}"
    echo -e "${RED}    ██║   ██║█████╗   ██║   ██║   ██║██║   ██║██║     ███████╗${RESET}"
    echo -e "${RED}    ██║   ██║╚════╝   ██║   ██║   ██║██║   ██║██║     ╚════██║${RESET}"
    echo -e "${RED}    ██║   ██║         ██║   ╚██████╔╝╚██████╔╝███████╗███████║${RESET}"
    echo -e "${RED}    ╚═╝   ╚═╝         ╚═╝    ╚═════╝  ╚═════╝ ╚══════╝╚══════╝${RESET}"
    echo ""
    echo -e "${CYAN}    flowbit OS ${KIT_VERSION}${RESET}"
    echo -e "${GRAY}    by flowbit${RESET}"
    echo -e "${GRAY}    ──────────────────────────────────────────────────${RESET}"
    echo ""
}

show_menu() {
    echo -e "${WHITE}    Module:${RESET}"
    echo ""
    echo -e "${CYAN}    [1]${WHITE}  Wiper            ${GRAY}— Festplatten sicher loeschen${RESET}"
    echo -e "${CYAN}    [2]${WHITE}  System Info       ${GRAY}— Hardware-Inventar, Intune Export${RESET}"
    echo -e "${CYAN}    [3]${WHITE}  Netzwerk Tools    ${GRAY}— Ping, DNS, Speedtest, Diagnose${RESET}"
    echo -e "${CYAN}    [4]${WHITE}  Hardware Test     ${GRAY}— RAM, Disk, CPU Stresstest${RESET}"
    echo -e "${CYAN}    [5]${WHITE}  BIOS Tools        ${GRAY}— Secure Boot, TPM, Asset Tag${RESET}"
    echo -e "${CYAN}    [6]${WHITE}  Backup / Restore  ${GRAY}— Images, Dateien, Netzwerk${RESET}"
    echo ""
    echo -e "${GRAY}    ──────────────────────────────────────────────────${RESET}"
    echo -e "${CYAN}    [s]${WHITE}  Shell             ${GRAY}— Bash oeffnen${RESET}"
    echo -e "${CYAN}    [i]${WHITE}  System Info Quick  ${GRAY}— Hardware-Uebersicht${RESET}"
    echo -e "${CYAN}    [r]${WHITE}  Reboot            ${GRAY}— Neu starten${RESET}"
    echo -e "${CYAN}    [x]${WHITE}  Shutdown           ${GRAY}— Herunterfahren${RESET}"
    echo ""
}

run_module() {
    local script="$1"
    if [[ -x "${MODULES_DIR}/${script}" ]]; then
        bash "${MODULES_DIR}/${script}"
    else
        echo -e "    ${RED}${script} nicht gefunden!${RESET}"
        read -n 1 -s -r -p "    Beliebige Taste..."
    fi
}

show_sysinfo_quick() {
    echo ""
    echo -e "${CYAN}    ── System Info ──────────────────────────────────${RESET}"
    echo ""
    local cpu=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
    local mem=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')
    local vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "N/A")
    local product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "N/A")
    local serial=$(cat /sys/class/dmi/id/product_serial 2>/dev/null || echo "N/A")
    local kernel=$(uname -r 2>/dev/null)

    echo -e "${WHITE}    Hersteller:  ${GRAY}${vendor}${RESET}"
    echo -e "${WHITE}    Modell:      ${GRAY}${product}${RESET}"
    echo -e "${WHITE}    Seriennr.:   ${GRAY}${serial}${RESET}"
    echo -e "${WHITE}    CPU:         ${GRAY}${cpu}${RESET}"
    echo -e "${WHITE}    RAM:         ${GRAY}${mem}${RESET}"
    echo -e "${WHITE}    Kernel:      ${GRAY}${kernel}${RESET}"
    echo ""

    echo -e "${CYAN}    ── Datentraeger ────────────────────────────────${RESET}"
    echo ""
    lsblk -d -o NAME,SIZE,MODEL,TRAN 2>/dev/null | while IFS= read -r line; do
        echo -e "${GRAY}    ${line}${RESET}"
    done
    echo ""

    echo -e "${CYAN}    ── Netzwerk ────────────────────────────────────${RESET}"
    echo ""
    ip -br addr 2>/dev/null | while IFS= read -r line; do
        echo -e "${GRAY}    ${line}${RESET}"
    done
    echo ""
    read -n 1 -s -r -p "    Beliebige Taste..."
}

main() {
    while true; do
        clear_screen
        show_header
        show_menu

        echo -ne "${WHITE}    Auswahl: ${CYAN}"
        read -r choice
        echo -e "${RESET}"

        case "$choice" in
            1) run_module "wiper.sh" ;;
            2) run_module "sysinfo.sh" ;;
            3) run_module "network.sh" ;;
            4) run_module "hwtest.sh" ;;
            5) run_module "biostools.sh" ;;
            6) run_module "backup.sh" ;;
            s|S)
                echo -e "${GRAY}    Tipp: 'exit' eingeben um zurueckzukehren${RESET}"
                echo ""
                /bin/bash
                ;;
            i|I) show_sysinfo_quick ;;
            r|R)
                echo -e "${YELLOW}    Neustart...${RESET}"
                sleep 1
                reboot
                ;;
            x|X)
                echo -e "${YELLOW}    Herunterfahren...${RESET}"
                sleep 1
                poweroff
                ;;
            *)
                echo -e "${RED}    Ungueltige Auswahl.${RESET}"
                sleep 1
                ;;
        esac
    done
}

main
