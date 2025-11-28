#!/bin/bash

# Uninstall the Firefox kiosk autostart service and start script if installed.

set -euo pipefail

# Determine the real user (support running via sudo)
TARGET_USER="${SUDO_USER:-${USER}}"
TARGET_HOME="$(eval echo ~${TARGET_USER})"

if [ -z "$TARGET_USER" ] || [ ! -d "$TARGET_HOME" ]; then
	echo "Cannot determine target user/home. Aborting." >&2
	exit 1
fi

SERVICE_NAME="firefox-kiosk.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
START_SCRIPT="$TARGET_HOME/.local/bin/start_kiosk.sh"

echo "Uninstalling Firefox kiosk autostart for user: $TARGET_USER (home: $TARGET_HOME)"

# Stop and disable the system service if it exists
if sudo systemctl list-unit-files | grep -q "^${SERVICE_NAME}" 2>/dev/null || [ -f "$SERVICE_PATH" ]; then
	echo "Stopping and disabling ${SERVICE_NAME}..."
	sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
	sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
	echo "Removing service file: $SERVICE_PATH"
	sudo rm -f "$SERVICE_PATH"
	sudo systemctl daemon-reload
	sudo systemctl reset-failed
	echo "Service ${SERVICE_NAME} removed."
else
	echo "Service ${SERVICE_NAME} not found; skipping systemd removal.";
fi

# Remove the user's start script if it exists
if [ -f "$START_SCRIPT" ]; then
	echo "Removing start script: $START_SCRIPT"
	sudo rm -f "$START_SCRIPT"
	# If the .local/bin directory is empty after removal, try to remove it (no error if not empty)
	if [ -d "$(dirname "$START_SCRIPT")" ] && [ -z "$(ls -A "$(dirname "$START_SCRIPT")")" ]; then
		sudo rmdir "$(dirname "$START_SCRIPT")" || true
	fi
else
	echo "Start script not present at $START_SCRIPT; skipping.";
fi

echo "Uninstall complete."