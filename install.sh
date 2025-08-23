#!/bin/bash

if [ "$(id -u)" -eq 0 ]; then
  echo "Do not run this script as root. Run as a normal user (sudo is used where required)." >&2
  exit 1
fi

# Install docker
curl -fsSL https://get.docker.com/ | sh
sudo usermod -aG docker $USER

# Install netplan for network configuration
sudo apt-get -y install netplan.io gh

cp netplan/raspap-bridge-br0.netplan /etc/netplan/
sudo netplan generate
sudo netplan apply

#For raspap
iptables -I DOCKER-USER -i src_if -o dst_if -j ACCEPT
iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE || iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -C FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT || iptables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -C FORWARD -i wlan0 -o eth0 -j ACCEPT || iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT
iptables-save

sudo apt-get install p7zip-full -y
# wget https://files.waveshare.com/upload/7/75/CM4_dt_blob.7z
# 7z x CM4_dt_blob.7z -O./CM4_dt_blob
# sudo chmod 777 -R CM4_dt_blob
# cd CM4_dt_blob/
# # If using two cameras and DSI1, please execute:
# sudo dtc -I dts -O dtb -o /boot/dt-blob.bin dt-blob-disp1-double_cam.dts


newgrp

# Set WLAN country to Germany
sudo sed -i '/^country=/d' /etc/wpa_supplicant/wpa_supplicant.conf
echo 'country=DE' | sudo tee -a /etc/wpa_supplicant/wpa_supplicant.conf

# Optionally set CRDA country (for older systems)
sudo sed -i '/^REGDOMAIN=/d' /etc/default/crda
echo 'REGDOMAIN=DE' | sudo tee -a /etc/default/crda

# Unblock Wi-Fi via rfkill and prevent blocking on boot
sudo rfkill unblock wifi
sudo systemctl mask rfkill.service
sudo systemctl mask rfkill.socket

wget https://raw.githubusercontent.com/vc_mipi_raspi/main/Makefile
