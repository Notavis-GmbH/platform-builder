#!/bin/bash

# Install a systemd oneshot service that aligns the CSI-2 media pipeline pad
# formats with the sensor before the camera container starts. Without it a
# mismatched pad format (e.g. csi2 source pad on Y16_1X16 while the sensor sends
# Y10_1X10) makes the RP1 CFE misread the line length, which tears the captured
# frame into displaced line groups.

set -euo pipefail

SCRIPT_DEST="/usr/local/sbin/set-csi-pipeline-format.sh"
SERVICE_PATH="/etc/systemd/system/csi-pipeline-format.service"

echo "Installing CSI pipeline format script to $SCRIPT_DEST"
sudo cp resources/set-csi-pipeline-format.sh "$SCRIPT_DEST"
sudo chmod +x "$SCRIPT_DEST"

echo "Installing csi-pipeline-format.service to $SERVICE_PATH"
sudo cp resources/csi-pipeline-format.service "$SERVICE_PATH"

sudo systemctl daemon-reload
sudo systemctl enable csi-pipeline-format.service

echo "Service installed. It runs before docker.service on boot."
echo "To apply it now, stop the camera container first:"
echo "  docker stop app_platform-camera-1"
echo "  sudo systemctl start csi-pipeline-format.service"
echo "  docker start app_platform-camera-1"
