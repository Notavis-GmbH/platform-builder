#!/bin/bash

# Install a systemd oneshot service that pins the rp1-cfe (camera CSI)
# interrupts to the CPU cores reserved for the camera container, so IRQ
# handling isn't delayed behind unrelated work on other cores.

set -euo pipefail

SCRIPT_DEST="/usr/local/sbin/set-camera-irq-affinity.sh"
SERVICE_PATH="/etc/systemd/system/camera-irq-affinity.service"

echo "Installing camera IRQ affinity script to $SCRIPT_DEST"
sudo cp resources/set-camera-irq-affinity.sh "$SCRIPT_DEST"
sudo chmod +x "$SCRIPT_DEST"

echo "Installing camera-irq-affinity.service to $SERVICE_PATH"
sudo cp resources/camera-irq-affinity.service "$SERVICE_PATH"

sudo systemctl daemon-reload
sudo systemctl enable --now camera-irq-affinity.service

echo "IRQ affinity service installed and applied. Check status with: sudo systemctl status camera-irq-affinity.service"
