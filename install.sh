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
iptables -t nat -C POSTROUTING -o end0 -j MASQUERADE || iptables -t nat -A POSTROUTING -o end0 -j MASQUERADE
iptables -C FORWARD -i end0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT || iptables -A FORWARD -i end0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -C FORWARD -i wlan0 -o end0 -j ACCEPT || iptables -A FORWARD -i wlan0 -o end0 -j ACCEPT
iptables-save > /dev/null
EOF



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

# Check libcamera version before building
REQUIRED_LIBCAMERA_VERSION="v0.0.0+5323-42d5b620"
REQUIRED_RPICAM_VERSION="v1.5.2"

if command -v libcamera-hello &> /dev/null; then
    echo "Checking installed libcamera version..."
    VERSION_OUTPUT=$(libcamera-hello --version 2>&1)
    
    INSTALLED_LIBCAMERA=$(echo "$VERSION_OUTPUT" | grep "libcamera build:" | awk '{print $3}')
    INSTALLED_RPICAM=$(echo "$VERSION_OUTPUT" | grep "rpicam-apps build:" | awk '{print $3}')
    
    echo "Installed rpicam-apps: ${INSTALLED_RPICAM}"
    echo "Installed libcamera: ${INSTALLED_LIBCAMERA}"
    echo "Required rpicam-apps: ${REQUIRED_RPICAM_VERSION}"
    echo "Required libcamera: ${REQUIRED_LIBCAMERA_VERSION}"
    
    if [ "${INSTALLED_LIBCAMERA}" = "${REQUIRED_LIBCAMERA_VERSION}" ] && [ "${INSTALLED_RPICAM}" = "${REQUIRED_RPICAM_VERSION}" ]; then
        echo "Correct libcamera and rpicam-apps versions are already installed. Skipping build."
    else
        echo "Version mismatch detected. Building libcamera and rpicam-apps..."
        make all
    fi
else
    echo "libcamera-hello not found. Building libcamera and rpicam-apps..."
    make all
fi

# Check if vc-mipi-driver-bcm2712 is already installed with the correct version
REQUIRED_VERSION="0.6.7"
PACKAGE_NAME="vc-mipi-driver-bcm2712"

if dpkg -l | grep -q "^ii  ${PACKAGE_NAME}"; then
    INSTALLED_VERSION=$(dpkg -l | grep "^ii  ${PACKAGE_NAME}" | awk '{print $3}')
    echo "Found ${PACKAGE_NAME} version ${INSTALLED_VERSION}"
    
    if [ "${INSTALLED_VERSION}" = "${REQUIRED_VERSION}" ]; then
        echo "${PACKAGE_NAME} version ${REQUIRED_VERSION} is already installed. Skipping installation."
    else
        echo "Installed version (${INSTALLED_VERSION}) does not match required version (${REQUIRED_VERSION}). Updating..."
        wget -N --timestamping https://github.com/VC-MIPI-modules/vc_mipi_raspi/releases/download/v0.6.7/vc-mipi-driver-bcm2712_0.6.7_arm64.deb
        sudo apt install ./vc-mipi-driver-bcm2712_0.6.7_arm64.deb -y
    fi
else
    echo "${PACKAGE_NAME} is not installed. Installing version ${REQUIRED_VERSION}..."
    wget -N --timestamping https://github.com/VC-MIPI-modules/vc_mipi_raspi/releases/download/v0.6.7/vc-mipi-driver-bcm2712_0.6.7_arm64.deb
    sudo apt install ./vc-mipi-driver-bcm2712_0.6.7_arm64.deb -y
fi

# Add log limit to 10 mb for docker globally
mkdir -p ~/.docker/
cp resources/config.json ~/.docker/config.json

sudo docker compose -f docker-compose.raspap.yml up -d

cd app_platform

sudo docker compose up -d
