#!/bin/bash

if [ "$(id -u)" -eq 0 ]; then
  echo "Do not run this script as root. Run as a normal user (sudo is used where required)." >&2
  exit 1
fi

echo "Starting platform installation..."

# directory for per-step logs
LOGDIR="$HOME/.platform_installer_logs"
mkdir -p "$LOGDIR"

# step counter
STEP_NO=0

# Color and symbol setup (UTF-8 symbols with ASCII fallback)
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
RESET="\033[0m"

# Unicode symbols (fall back to ASCII if terminal doesn't support UTF-8)
CHECK_MARK="\xE2\x9C\x94"  # ✔
CROSS_MARK="\xE2\x9D\x96"  # ✖
INFO_MARK="\xE2\x84\xB9"   # ℹ

# Quick UTF-8 check: if locale doesn't support, use ASCII
if ! printf "%b" "$CHECK_MARK" >/dev/null 2>&1; then
    CHECK_MARK="[OK]"
    CROSS_MARK="[FAIL]"
    INFO_MARK="[i]"
fi

# run_step: run a command, redirect stdout/stderr to a per-step log file
# usage: run_step "Title" "command to run"
run_step() {
    STEP_NO=$((STEP_NO+1))
    local title="$1"
    shift
    local slug
    slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '_' | sed 's/_\+/_/g' | sed 's/^_//;s/_$//')
    local logfile="$LOGDIR/step_${STEP_NO}_${slug}.log"

    echo
    echo -e "${YELLOW}${INFO_MARK} Step ${STEP_NO}: ${title}...${RESET}"
    echo -e "  -> writing output to ${BLUE}${logfile}${RESET}"

    local rc
    # Usage patterns:
    # 1) run_step "Title" -- cmd arg1 arg2 ...   -> runs command directly (no shell parsing)
    # 2) run_step "Title" "some complex shell string" -> legacy: runs via "bash -lc"

    # Start the command in background so we can show a spinner while it runs
    if [ "$#" -gt 0 ] && [ "$1" = "--" ]; then
        shift
        ("$@") >"$logfile" 2>&1 &
        cmd_pid=$!
    else
        local cmd="$*"
        bash -lc "$cmd" >"$logfile" 2>&1 &
        cmd_pid=$!
    fi

    # spinner with elapsed time
    local spinner_chars=( '|' '/' '-' '\\' )
    local i=0
    local start_ts
    start_ts=$(date +%s)
    printf ""
    while kill -0 "$cmd_pid" >/dev/null 2>&1; do
        local now elapsed elapsed_fmt ch
        now=$(date +%s)
        elapsed=$((now - start_ts))
        if [ "$elapsed" -ge 3600 ]; then
            local hours=$((elapsed/3600))
            local mins=$((elapsed%3600/60))
            local secs=$((elapsed%60))
            elapsed_fmt=$(printf "%d:%02d:%02d" "$hours" "$mins" "$secs")
        else
            local mins=$((elapsed/60))
            local secs=$((elapsed%60))
            elapsed_fmt=$(printf "%02d:%02d" "$mins" "$secs")
        fi
        ch=${spinner_chars[i]}
        i=$(( (i + 1) % ${#spinner_chars[@]} ))
        echo -ne "\r  ${YELLOW}${INFO_MARK} Step ${STEP_NO}: ${title} ... ${ch} (${elapsed_fmt}) ${RESET}"
        sleep ${INSTALLER_SPINNER_INTERVAL:-0.12}
    done

    # wait for process and capture exit code
    wait "$cmd_pid" 2>/dev/null || true
    rc=$?

    # compute total elapsed and clear spinner line
    local end_ts total_elapsed total_fmt
    end_ts=$(date +%s)
    total_elapsed=$((end_ts - start_ts))
    if [ "$total_elapsed" -ge 3600 ]; then
        local th=$((total_elapsed/3600))
        local tm=$((total_elapsed%3600/60))
        local ts=$((total_elapsed%60))
        total_fmt=$(printf "%d:%02d:%02d" "$th" "$tm" "$ts")
    else
        local tm=$((total_elapsed/60))
        local ts=$((total_elapsed%60))
        total_fmt=$(printf "%02d:%02d" "$tm" "$ts")
    fi
    echo -ne "\r\033[K"

    if [ $rc -eq 0 ]; then
        echo -e "${GREEN}${CHECK_MARK} Step ${STEP_NO}: ${title} — SUCCESS (${total_fmt})${RESET}"
        if [ "${INSTALLER_VERBOSE:-0}" -eq 1 ]; then
            echo -e "${BLUE}Full log (${logfile}):${RESET}"
            sed 's/^/  /' "$logfile"
        else
            echo -e "${BLUE}Log (last 5 lines):${RESET}"
            tail -n 5 "$logfile" | sed 's/^/  /'
        fi
    else
        echo -e "${RED}${CROSS_MARK} Step ${STEP_NO}: ${title} — FAILED (exit ${rc}) (${total_fmt})${RESET}"
        echo -e "${RED}Last 100 lines of log (${logfile}):${RESET}"
        tail -n 100 "$logfile" | sed 's/^/  /'
        echo -e "Full log available at: ${BLUE}${logfile}${RESET}"
        return $rc
    fi
}
# Install docker only if not already installed
echo "Step 1: Checking Docker installation..."
if ! command -v docker &> /dev/null; then
    run_step "Install Docker" "curl -fsSL https://get.docker.com/ | sh && sudo usermod -aG docker \$USER && sudo mkdir -p /etc/docker && echo '{ \"log-driver\": \"json-file\", \"log-opts\": { \"max-size\": \"10m\" } }' | sudo tee /etc/docker/daemon.json && sudo systemctl restart docker"
else
    echo "Docker is already installed. Skipping Docker installation."
fi

# Install netplan for network configuration and configure system (as root)
echo "Step 2: Configuring network and installing packages..."
run_step "Install packages" "sudo apt-get -y install netplan.io gh p7zip-full"
run_step "Copy netplan configuration" "sudo cp netplan/raspap-bridge-br0.netplan.yaml /etc/netplan/ && sudo chmod 600 /etc/netplan/raspap-bridge-br0.netplan.yaml"
run_step "Apply netplan" "sudo netplan generate && sudo netplan apply"
## iptables helper for raspap: use a shell function so run_step can call it directly
setup_raspap_iptables() {
sudo tee /etc/nftables.conf > /dev/null <<'EOF'
table ip nat {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
    }

    chain output {
        type nat hook output priority -100; policy accept;
    }

    chain postrouting {
        type nat hook postrouting priority 100; policy accept;

        # Dein Masquerade für end0
        oifname "end0" masquerade

        # Docker-Subnetze Masqueraden
        ip saddr 172.17.0.0/16 oifname != "docker0" masq
        ip saddr 172.18.0.0/16 oifname != "docker0" masq
        ip saddr 172.19.0.0/16 oifname != "docker0" masq
        ip saddr 192.168.0.0/16 oifname != "docker0" masq
    }
}
EOF

sudo nft -f /etc/nftables.conf
sudo systemctl enable --now nftables

}

run_step "Configure iptables for raspap" -- setup_raspap_iptables



# Set WLAN country to Germany (for Debian 13/modern Raspberry Pi OS)
echo "Step 3: Setting WLAN country to Germany..."
if command -v raspi-config &> /dev/null; then
    run_step "Set WLAN country (raspi-config)" "sudo raspi-config nonint do_wifi_country DE"
else
    run_step "Set WLAN country (iw) and persist" "sudo iw reg set DE && if [ -f /etc/default/crda ]; then sudo sed -i '/^REGDOMAIN=/d' /etc/default/crda && echo 'REGDOMAIN=DE' | sudo tee -a /etc/default/crda; fi && if [ -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then sudo sed -i '/^country=/d' /etc/wpa_supplicant/wpa_supplicant.conf && echo 'country=DE' | sudo tee -a /etc/wpa_supplicant/wpa_supplicant.conf; fi"
    echo "WLAN country set using iw and configuration files."
fi

# Unblock Wi-Fi via rfkill and prevent blocking on boot
echo "Step 4: Unblocking Wi-Fi..."
run_step "Unblock Wi-Fi and mask rfkill" "sudo rfkill unblock wifi && sudo systemctl mask rfkill.service && sudo systemctl mask rfkill.socket"

# Check libcamera version before building
echo "Step 5: Checking and installing libcamera and rpicam-apps..."
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
        run_step "Build libcamera and rpicam-apps" "make all"
    fi
else
    echo "libcamera-hello not found. Building libcamera and rpicam-apps..."
    run_step "Build libcamera and rpicam-apps" "make all"
fi

# Check if vc-mipi-driver-bcm2712 is already installed with the correct version
echo "Step 6: Checking and installing vc-mipi-driver..."
REQUIRED_VERSION="0.6.7"
PACKAGE_NAME="vc-mipi-driver-bcm2712"

if dpkg -l | grep -q "^ii  ${PACKAGE_NAME}"; then
    INSTALLED_VERSION=$(dpkg -l | grep "^ii  ${PACKAGE_NAME}" | awk '{print $3}')
    echo "Found ${PACKAGE_NAME} version ${INSTALLED_VERSION}"
    
    if [ "${INSTALLED_VERSION}" = "${REQUIRED_VERSION}" ]; then
        echo "${PACKAGE_NAME} version ${REQUIRED_VERSION} is already installed. Skipping installation."
    else
        echo "Installed version (${INSTALLED_VERSION}) does not match required version (${REQUIRED_VERSION}). Updating..."
        run_step "Install vc-mipi-driver (update)" "wget -N --timestamping https://github.com/VC-MIPI-modules/vc_mipi_raspi/releases/download/v0.6.7/vc-mipi-driver-bcm2712_0.6.7_arm64.deb && sudo apt install ./vc-mipi-driver-bcm2712_0.6.7_arm64.deb -y"
    fi
else
    echo "${PACKAGE_NAME} is not installed. Installing version ${REQUIRED_VERSION}..."
    run_step "Install vc-mipi-driver" "wget -N --timestamping https://github.com/VC-MIPI-modules/vc_mipi_raspi/releases/download/v0.6.7/vc-mipi-driver-bcm2712_0.6.7_arm64.deb && sudo apt install ./vc-mipi-driver-bcm2712_0.6.7_arm64.deb -y"
fi

# Add log limit to 10 mb for docker globally
echo "Step 7: Configuring Docker logging..."
run_step "Configure Docker logging" "mkdir -p ~/.docker/ && cp resources/config.json ~/.docker/config.json"

echo "Step 8: Starting raspap services..."
run_step "Start raspap services" "sudo docker compose -f docker-compose.raspap.yml up -d"

echo "Step 9: Starting app platform services..."
run_step "Pull app platform images" "cd app_platform && sudo docker compose pull"
run_step "Start app platform services" "cd app_platform && sudo docker compose up -d --remove-orphans"

echo "Step 10: Uninstalling autostart kiosk..."
run_step "Uninstall autostart kiosk" "sudo bash uninstallAutostartKiosk.sh"

# Archive installer logs and copy to /var/log/platform-installer for diagnostics
archive_installer_logs() {
    TS=$(date +%Y%m%d-%H%M%S)
    TAR="$HOME/platform_install_logs_${TS}.tar.gz"
    if [ -d "$LOGDIR" ]; then
        tar -czf "$TAR" -C "$LOGDIR" .
        sudo mkdir -p /var/log/platform-installer
        sudo cp "$TAR" /var/log/platform-installer/
        echo "Archived installer logs to $TAR and copied to /var/log/platform-installer/"
    else
        echo "No installer logs found at $LOGDIR"
    fi
}

run_step "Archive installer logs" -- archive_installer_logs

echo "Platform installation completed successfully!"
