#!/bin/bash

mkdir -p ~/.local/bin
cp resources/start_kiosk.sh ~/.local/bin/
chmod +x ~/.local/bin/start_kiosk.sh


mkdir -p ~/.config/systemd/user
cp resources/firefox-kiosk.service /etc/systemd/system/


sudo systemctl daemon-reload
sudo systemctl enable firefox-kiosk.service
sudo systemctl start firefox-kiosk.service