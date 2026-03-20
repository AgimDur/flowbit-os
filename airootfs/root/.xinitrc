#!/bin/bash
# flowbit OS Kiosk Mode

# Disable screen blanking
xset s off 2>/dev/null
xset -dpms 2>/dev/null
xset s noblank 2>/dev/null

# Hide cursor
unclutter -idle 3 -root &>/dev/null &

# Wait for X to settle
sleep 1

# Get screen resolution reliably
SCREEN_RES=$(xrandr 2>/dev/null | grep -m1 " connected" | grep -oP "\d+x\d+" | head -1)
if [ -z "$SCREEN_RES" ]; then
  SCREEN_RES=$(xdpyinfo 2>/dev/null | grep dimensions | awk "{print \$2}")
fi
WIDTH=$(echo $SCREEN_RES | cut -dx -f1)
HEIGHT=$(echo $SCREEN_RES | cut -dx -f2)
[ -z "$WIDTH" ] && WIDTH=1920
[ -z "$HEIGHT" ] && HEIGHT=1080

echo "Screen: ${WIDTH}x${HEIGHT}" > /tmp/screen-info.txt

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
  http://localhost:8080 &

CHROME_PID=$!

# Force fullscreen after Chromium starts
sleep 2
xdotool key F11 2>/dev/null
sleep 1
# Resize window to fill screen
WID=$(xdotool search --onlyvisible --name "flowbit" 2>/dev/null | head -1)
if [ -n "$WID" ]; then
  xdotool windowactivate $WID 2>/dev/null
  xdotool windowmove $WID 0 0 2>/dev/null
  xdotool windowsize $WID $WIDTH $HEIGHT 2>/dev/null
  xdotool key F11 2>/dev/null
fi

wait $CHROME_PID
