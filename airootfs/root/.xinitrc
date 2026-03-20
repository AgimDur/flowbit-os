#!/bin/bash
# flowbit OS Kiosk Mode

# Disable screen blanking
xset s off 2>/dev/null
xset -dpms 2>/dev/null
xset s noblank 2>/dev/null

# Hide cursor
unclutter -idle 3 -root &>/dev/null &

# Start window manager (required for Chromium)
openbox &

# Wait for X to settle
sleep 1

# Get screen resolution
SCREEN_RES=$(xrandr 2>/dev/null | grep -m1 " connected" | grep -o "[0-9]*x[0-9]*" | head -1)
if [ -z "$SCREEN_RES" ]; then
  SCREEN_RES=$(xdpyinfo 2>/dev/null | grep dimensions | awk "{print \$2}")
fi
WIDTH=$(echo $SCREEN_RES | cut -dx -f1)
HEIGHT=$(echo $SCREEN_RES | cut -dx -f2)
[ -z "$WIDTH" ] && WIDTH=1920
[ -z "$HEIGHT" ] && HEIGHT=1080

# Wait for web server
for i in $(seq 1 20); do
  curl -s http://localhost:8080 >/dev/null 2>&1 && break
  sleep 0.5
done

# Start Chromium in kiosk mode
chromium \
  --no-first-run \
  --no-default-browser-check \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --disable-features=TranslateUI \
  --noerrdialogs \
  --disable-pinch \
  --overscroll-history-navigation=0 \
  --kiosk \
  --start-fullscreen \
  --start-maximized \
  --window-position=0,0 \
  --window-size=${WIDTH},${HEIGHT} \
  --force-device-scale-factor=1 \
  http://localhost:8080
