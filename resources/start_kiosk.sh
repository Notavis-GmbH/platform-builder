#!/bin/bash

# Wait until localhost:80 is reachable
KIOSK_URL="${KIOSK_URL:-http://localhost:80}"

# Wait for the app shell itself, not just for any answer on port 80. A bare
# 200 can still be a placeholder page while the stack is coming up.
for _ in $(seq 1 150); do
    if curl -sf "$KIOSK_URL" | grep -q "app-root"; then
        break
    fi
    echo "Waiting for local server..."
    sleep 2
done

# Kiosk profile in a dedicated directory so a broken profile can be reset
# without touching the user's default Chromium data.
KIOSK_PROFILE="${HOME}/.config/chromium-kiosk"
mkdir -p "$KIOSK_PROFILE"

# Chromium keeps its HTTP cache under ~/.cache/chromium, outside --user-data-dir.
# Pin it into the kiosk profile and drop it on every start so a stale shell can
# never be replayed from disk after an update or a config change.
KIOSK_CACHE="$KIOSK_PROFILE/Cache"
rm -rf "$KIOSK_CACHE"
mkdir -p "$KIOSK_CACHE"

# Suppress the "Chromium didn't shut down correctly" restore bubble after a
# power cut, which would otherwise block the kiosk view.
PREFS="$KIOSK_PROFILE/Default/Preferences"
if [ -f "$PREFS" ]; then
    sed -i 's/"exit_type":"[^"]*"/"exit_type":"Normal"/; s/"exited_cleanly":false/"exited_cleanly":true/' "$PREFS" || true
fi

# Launch Chromium in fullscreen kiosk mode (Wayland/labwc session)
exec chromium \
    --ozone-platform=wayland \
    --kiosk \
    --start-fullscreen \
    --user-data-dir="$KIOSK_PROFILE" \
    --disk-cache-dir="$KIOSK_CACHE" \
    --noerrdialogs \
    --disable-infobars \
    --disable-session-crashed-bubble \
    --disable-features=TranslateUI \
    --disable-pinch \
    --overscroll-history-navigation=0 \
    --autoplay-policy=no-user-gesture-required \
    --password-store=basic \
    --check-for-update-interval=31536000 \
    ${KIOSK_EXTRA_ARGS:-} \
    "$KIOSK_URL"
