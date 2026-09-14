#!/bin/bash

# Uninstall the camera IRQ affinity service and script if installed.

set -euo pipefail

SERVICE_NAME="camera-irq-affinity.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
SCRIPT_DEST="/usr/local/sbin/set-camera-irq-affinity.sh"

echo "Uninstalling camera IRQ affinity service..."

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

if [ -f "$SCRIPT_DEST" ]; then
	echo "Removing script: $SCRIPT_DEST"
	sudo rm -f "$SCRIPT_DEST"
else
	echo "Script not present at $SCRIPT_DEST; skipping.";
fi

echo "Uninstall complete."
