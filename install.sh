#!/bin/bash

if [ "$(id -u)" -eq 0 ]; then
  echo "Do not run this script as root. Run as a normal user (sudo is used where required)." >&2
  exit 1
fi

# Install docker only if not already installed
if ! command -v docker &> /dev/null; then
    echo "Docker not found. Installing Docker..."
    curl -fsSL https://get.docker.com/ | sh
    sudo usermod -aG docker $USER
    sudo mkdir -p /etc/docker
    echo '{ "log-driver": "json-file", "log-opts": { "max-size": "10m" } }' | sudo tee /etc/docker/daemon.json
    sudo systemctl ctl restart docker
else
    echo "Docker is already installed. Skipping Docker installation."
fi

# Install netplan for network configuration and configure system (as root)
sudo -s << 'EOF'
apt-get -y install netplan.io gh p7zip-full

cp netplan/raspap-bridge-br0.netplan.yaml /etc/netplan/
chmod 600 /etc/netplan/raspap-bridge-br0.netplan.yaml
netplan generate
netplan apply

#For raspap
iptables -I DOCKER-USER -i src_if -o dst_if -j ACCEPT
iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE || iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -C FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT || iptables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -C FORWARD -i wlan0 -o eth0 -j ACCEPT || iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT
iptables-save > /dev/null
EOF

# wget https://files.waveshare.com/upload/7/75/CM4_dt_blob.7z
# 7z x CM4_dt_blob.7z -O./CM4_dt_blob
# sudo chmod 777 -R CM4_dt_blob
# cd CM4_dt_blob/
# # If using two cameras and DSI1, please execute:
# sudo dtc -I dts -O dtb -o /boot/dt-blob.bin dt-blob-disp1-double_cam.dts

# Refresh group membership for docker (equivalent to newgrp)
echo "Docker group membership refreshed. You may need to log out and back in for full effect."

# Set WLAN country to Germany (for Debian 13/modern Raspberry Pi OS)
if command -v raspi-config &> /dev/null; then
    # Use raspi-config if available (Raspberry Pi OS)
    sudo raspi-config nonint do_wifi_country DE
else
    # Fallback for other Debian systems - use iw regulatory domain
    sudo iw reg set DE
    # Make it persistent by setting in /etc/default/crda if the file exists
    if [ -f /etc/default/crda ]; then
        sudo sed -i '/^REGDOMAIN=/d' /etc/default/crda
        echo 'REGDOMAIN=DE' | sudo tee -a /etc/default/crda
    fi
    # Also try the old wpa_supplicant method as fallback
    if [ -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
        sudo sed -i '/^country=/d' /etc/wpa_supplicant/wpa_supplicant.conf
        echo 'country=DE' | sudo tee -a /etc/wpa_supplicant/wpa_supplicant.conf
    fi
fi

# Unblock Wi-Fi via rfkill and prevent blocking on boot
sudo rfkill unblock wifi
sudo systemctl mask rfkill.service
sudo systemctl mask rfkill.socket

# # Setup Firefox kiosk mode with Wayland/Sway
# mkdir -p ~/kiosk ~/.config/sway

# # Create Firefox kiosk startup script
# cat << 'KIOSK_EOF' > ~/kiosk/start-kiosk.sh
# #!/bin/bash
# # Firefox Kiosk Mode Startup Script for Desktop Session

# # Wait for desktop session to be ready
# sleep 10

# # Kill any existing Firefox processes
# pkill firefox-esr 2>/dev/null || true

# # Wait for localhost:80 to be available
# echo "Waiting for localhost:80 to be available..."
# while ! curl -s --connect-timeout 2 http://127.0.0.1:80 >/dev/null 2>&1; do
#     echo "Waiting for service on port 80..."
#     sleep 2
# done
# echo "Service is ready!"

# # Additional wait to ensure service is fully loaded
# sleep 3

# # Start Firefox in kiosk mode using IP address instead of localhost
# firefox-esr --kiosk --new-instance --no-remote \
#     --disable-extensions \
#     --disable-plugins \
#     --disable-translate \
#     --disable-infobars \
#     --disable-suggestions-service \
#     --disable-ipc-flooding-protection \
#     --no-first-run \
#     --no-default-browser-check \
#     --homepage=http://127.0.0.1:80 \
#     http://127.0.0.1:80 &

# # Keep Firefox running and restart if it crashes
# while true; do
#     wait $!
#     echo "Firefox crashed, restarting in 5 seconds..."
#     sleep 5
#     pkill firefox-esr 2>/dev/null || true
#     sleep 2
#     firefox-esr --kiosk --new-instance --no-remote \
#         --disable-extensions \
#         --disable-plugins \
#         --disable-translate \
#         --disable-infobars \
#         --disable-suggestions-service \
#         --disable-ipc-flooding-protection \
#         --no-first-run \
#         --no-default-browser-check \
#         --homepage=http://127.0.0.1:80 \
#         http://127.0.0.1:80 &
# done
# KIOSK_EOF

# chmod +x ~/kiosk/start-kiosk.sh
# echo "Created Firefox kiosk startup script at ~/kiosk/start-kiosk.sh"
# # Create Sway configuration for kiosk mode
# cat << 'SWAY_EOF' > ~/.config/sway/config
# # Sway Kiosk Configuration

# # Disable title bars and borders
# default_border none
# default_floating_border none

# # Hide cursor after 1 second
# seat * hide_cursor 1000

# # Disable screen blanking/power management
# output * dpms on

# # Auto-start Firefox in kiosk mode
# exec ~/kiosk/start-kiosk.sh

# # # Disable some key bindings for kiosk security
# # # Keep essential ones for maintenance
# # bindsym $mod+Return exec foot
# # bindsym $mod+q kill
# # bindsym $mod+Shift+c reload
# # bindsym $mod+Shift+e exit

# # Set mod key to Super (Windows key)
# set $mod Mod4
# SWAY_EOF

# # Install Wayland session for RPI Connect compatibility
# sudo apt-get install -y wayfire

# # Configure LightDM for auto-login with Wayland session
# sudo tee /etc/lightdm/lightdm.conf > /dev/null << 'LIGHTDM_EOF'
# [Seat:*]
# autologin-user=notavis
# autologin-user-timeout=0
# user-session=wayfire
# LIGHTDM_EOF

# # Create desktop autostart entry to run Firefox kiosk in current session
# mkdir -p ~/.config/autostart
# cat << 'AUTOSTART_EOF' > ~/.config/autostart/kiosk.desktop
# [Desktop Entry]
# Type=Application
# Name=Kiosk Mode Firefox
# Exec=/home/notavis/kiosk/start-kiosk.sh
# Hidden=false
# NoDisplay=false
# X-GNOME-Autostart-enabled=true
# StartupNotify=false
# AUTOSTART_EOF

# # Create Wayfire autostart configuration
# mkdir -p ~/.config/wayfire
# cat << 'WAYFIRE_EOF' > ~/.config/wayfire.ini
# [autostart]
# kiosk = /home/notavis/kiosk/start-kiosk.sh
# panel = wf-panel
# background = wf-background

# [core]
# plugins = animate autostart command cube expo fast-switcher fisheye grid idle invert move oswitch place resize switcher vswitch window-rules wobbly zoom

# [input]
# xkb_layout = de
# xkb_variant = 
# cursor_theme = default
# cursor_size = 24
# WAYFIRE_EOF

# # Also create a simple script to start kiosk manually if needed
# cat << 'MANUAL_EOF' > ~/start-kiosk-now.sh
# #!/bin/bash
# echo "Starting Firefox kiosk mode..."
# ~/kiosk/start-kiosk.sh
# MANUAL_EOF

# chmod +x ~/start-kiosk-now.sh

# # Ensure curl is installed for the kiosk script
# sudo apt-get install -y curl

# echo "Firefox kiosk mode setup complete. The system will start in kiosk mode after reboot."
# echo "Kiosk will display: http://localhost:80"

# wget -N --timestamping  https://raw.githubusercontent.com/VC-MIPI-modules/vc_mipi_raspi/main/Makefile

make all

wget -N --timestamping  https://github.com/VC-MIPI-modules/vc_mipi_raspi/releases/download/v0.6.7/vc-mipi-driver-bcm2712_0.6.7_arm64.deb

sudo apt install ./vc-mipi-driver-bcm2712_0.6.7_arm64.deb -y

# Add log limit to 10 mb for docker globally

cp resources/config.json /home/notavis/.docker/config.json

docker compose -f docker-compose.raspap.yml up -d

cd app_platform

docker compose up -d