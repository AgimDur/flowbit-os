# flowbit OS Auto-Start
if [[ "$(tty)" == "/dev/tty1" ]]; then
    echo ""
    echo -e "\033[1;36m    flowbit OS\033[0m"
    echo ""
    echo -e "\033[0;37m    [1] Web-UI starten (Grafisch)\033[0m"
    echo -e "\033[0;37m    [2] CLI-Menue\033[0m"
    echo ""
    echo -e "\033[2m    Automatischer Start Web-UI in 5 Sekunden...\033[0m"
    echo ""
    
    # Read with timeout - default to GUI
    choice=""
    read -t 5 -n 1 choice
    
    case "$choice" in
        2)
            /opt/kit/kit.sh
            ;;
        *)
            echo ""
            echo -e "\033[0;37m    Starte Web-UI...\033[0m"
            # Start web server first
            python3 /opt/kit/webui/server.py &>/dev/null &
            sleep 1
            
            # Try to start X
            if startx 2>/tmp/startx.log; then
                true
            else
                echo ""
                echo -e "\033[1;31m    X11 konnte nicht gestartet werden.\033[0m"
                echo -e "\033[0;37m    Starte CLI-Menue...\033[0m"
                echo ""
                echo -e "\033[2m    Web-UI erreichbar unter: http://$(hostname -I | awk '{print $1}'):8080\033[0m"
                echo ""
                sleep 3
                /opt/kit/kit.sh
            fi
            ;;
    esac
fi
