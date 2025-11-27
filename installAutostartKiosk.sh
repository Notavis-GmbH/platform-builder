#!/bin/bash

# Determine the real user (support running via sudo)
TARGET_USER="${SUDO_USER:-${USER}}"
TARGET_HOME="$(eval echo ~${TARGET_USER})"

if [ -z "$TARGET_USER" ] || [ ! -d "$TARGET_HOME" ]; then
	echo "Cannot determine target user/home. Aborting." >&2
	exit 1
fi

echo "Installing kiosk autostart for user: $TARGET_USER (home: $TARGET_HOME)"

# Install start script into the user's local bin
sudo -u "$TARGET_USER" mkdir -p "$TARGET_HOME/.local/bin"
sudo cp resources/start_kiosk.sh "$TARGET_HOME/.local/bin/start_kiosk.sh"
sudo chmod +x "$TARGET_HOME/.local/bin/start_kiosk.sh"
sudo chown "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.local/bin/start_kiosk.sh"

# Install system service (system-wide) but set User and HOME dynamically
SERVICE_PATH="/etc/systemd/system/firefox-kiosk.service"
sudo tee "$SERVICE_PATH" > /dev/null <<EOF
[Unit]
Description=Firefox Kiosk Autostart
After=graphical.target network-online.target

[Service]
User=$TARGET_USER
Environment=DISPLAY=:0
Environment=XAUTHORITY=$TARGET_HOME/.Xauthority
ExecStart=$TARGET_HOME/.local/bin/start_kiosk.sh
Restart=always

[Install]
WantedBy=graphical.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now firefox-kiosk.service

echo "Autostart service installed and started. Check status with: sudo systemctl status firefox-kiosk.service"