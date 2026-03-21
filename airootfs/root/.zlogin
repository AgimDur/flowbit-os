# flowbit OS Auto-Start
if [[ "$(tty)" == "/dev/tty1" ]]; then
    exec bash /opt/kit/boot.sh
fi
