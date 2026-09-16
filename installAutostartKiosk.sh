#!/bin/bash

# Determine the real user (support running via sudo)
TARGET_USER="${SUDO_USER:-${USER}}"
TARGET_HOME="$(eval echo ~${TARGET_USER})"

if [ -z "$TARGET_USER" ] || [ ! -d "$TARGET_HOME" ]; then
	echo "Cannot determine target user/home. Aborting." >&2
	exit 1
fi

echo "Installing kiosk autostart for user: $TARGET_USER (home: $TARGET_HOME)"

# Chromium is required for the kiosk view
if ! command -v chromium >/dev/null 2>&1; then
	echo "chromium not found. Install it first: sudo apt-get install -y chromium" >&2
	exit 1
fi

# Remove the legacy Cog kiosk service so both do not fight over the display
LEGACY_SERVICE="/etc/systemd/system/cog-kiosk.service"
if [ -f "$LEGACY_SERVICE" ]; then
	echo "Removing legacy cog-kiosk.service"
	sudo systemctl disable --now cog-kiosk.service 2>/dev/null || true
	sudo rm -f "$LEGACY_SERVICE"
fi

# Install start script into the user's local bin
sudo -u "$TARGET_USER" mkdir -p "$TARGET_HOME/.local/bin"
sudo cp resources/start_kiosk.sh "$TARGET_HOME/.local/bin/start_kiosk.sh"
sudo chmod +x "$TARGET_HOME/.local/bin/start_kiosk.sh"
sudo chown "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.local/bin/start_kiosk.sh"

# Install system service (system-wide) but set User and HOME dynamically
SERVICE_PATH="/etc/systemd/system/chromium-kiosk.service"
TARGET_UID=$(id -u "$TARGET_USER")
sudo tee "$SERVICE_PATH" > /dev/null <<EOF
[Unit]
Description=Chromium Kiosk Autostart
After=graphical.target network-online.target

[Service]
User=$TARGET_USER
Environment=XDG_RUNTIME_DIR=/run/user/$TARGET_UID
Environment=WAYLAND_DISPLAY=wayland-0
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$TARGET_UID/bus
ExecStart=$TARGET_HOME/.local/bin/start_kiosk.sh
Restart=always

[Install]
WantedBy=graphical.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now chromium-kiosk.service

echo "Autostart service installed and started. Check status with: sudo systemctl status chromium-kiosk.service"
