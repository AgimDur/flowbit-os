#\!/bin/bash
# flowbit OS Kiosk Mode

# Disable screen blanking
xset s off 2>/dev/null
xset -dpms 2>/dev/null
xset s noblank 2>/dev/null

# Hide cursor
unclutter -idle 3 -root &>/dev/null &

# Get actual screen resolution
sleep 0.5
SCREEN_RES=$(xdpyinfo 2>/dev/null | grep dimensions | awk "{print \$2}")
WIDTH=$(echo $SCREEN_RES | cut -dx -f1)
HEIGHT=$(echo $SCREEN_RES | cut -dx -f2)
[ -z "$WIDTH" ] && WIDTH=1920
[ -z "$HEIGHT" ] && HEIGHT=1080

# Wait for web server
sleep 1

# Start Chromium in kiosk mode with actual screen size
exec chromium \
  --no-first-run \
  --no-default-browser-check \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --disable-features=TranslateUI \
  --disable-gpu \
  --no-sandbox \
  --kiosk \
  --noerrdialogs \
  --disable-pinch \
  --overscroll-history-navigation=0 \
  --start-fullscreen \
  --start-maximized \
  --window-position=0,0 \
  --window-size=${WIDTH},${HEIGHT} \
  http://localhost:8080
