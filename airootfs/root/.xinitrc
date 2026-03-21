#!/bin/bash
# flowbit OS Kiosk Mode

export LANG=en_US.UTF-8
export LC_ALL=C

# Disable screen blanking
xset s off 2>/dev/null
xset -dpms 2>/dev/null
xset s noblank 2>/dev/null

# Hide cursor
unclutter -idle 3 -root &>/dev/null &

# Start window manager
openbox &
sleep 1

# Get screen resolution
SCREEN_RES=$(xrandr 2>/dev/null | grep -m1 " connected" | grep -o "[0-9]*x[0-9]*" | head -1)
WIDTH=$(echo $SCREEN_RES | cut -dx -f1)
HEIGHT=$(echo $SCREEN_RES | cut -dx -f2)
[ -z "$WIDTH" ] && WIDTH=1920
[ -z "$HEIGHT" ] && HEIGHT=1080

# Wait for web server
for i in $(seq 1 30); do
  curl -s http://localhost:8080 >/dev/null 2>&1 && break
  sleep 0.5
done

# Start Chromium in kiosk mode
exec chromium \
  --no-first-run \
  --no-default-browser-check \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --disable-features=TranslateUI \
  --noerrdialogs \
  --disable-pinch \
  --overscroll-history-navigation=0 \
  --kiosk \
  --no-sandbox \
  --disable-gpu \
  --start-fullscreen \
  --start-maximized \
  --window-position=0,0 \
  --window-size=${WIDTH},${HEIGHT} \
  --force-device-scale-factor=1 \
  --user-data-dir=/tmp/chromium-data \
  http://localhost:8080
