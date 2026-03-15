# KIT Auto-Start
if [[ "$(tty)" == "/dev/tty1" ]]; then
    /opt/kit/kit.sh
fi
