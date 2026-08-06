#!/bin/bash

# Uninstall script for the platform-builder installation performed by install.sh.
#
# Scope (app-level teardown): stops/removes the app_platform and raspap docker
# compose services, removes the Firefox kiosk autostart, removes the
# vc-mipi-driver-bcm2712 package and its boot config, and cleans up installer
# logs / build metadata.
#
# Left untouched on purpose, since they are system-wide changes other things
# on the Pi may depend on: Docker itself, apt packages installed by install.sh
# (netplan.io, gh, p7zip-full), the netplan bridge config, the Avahi config,
# the nftables/masquerade config, the WLAN country setting, and the rfkill
# service mask.

set -uo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "Do not run this script as root. Run as a normal user (sudo is used where required)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

YELLOW="\033[0;33m"
GREEN="\033[0;32m"
RED="\033[0;31m"
RESET="\033[0m"

ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

if [ "$ASSUME_YES" -ne 1 ]; then
    echo "This will stop and remove the app_platform and raspap docker services,"
    echo "remove the Firefox kiosk autostart, remove the vc-mipi-driver-bcm2712"
    echo "package, and clean up installer logs/build metadata."
    read -r -p "Continue? [y/N] " reply
    case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "Aborted."; exit 1 ;;
    esac
fi

run_step() {
    local title="$1"
    shift
    echo -e "${YELLOW}==> ${title}...${RESET}"
    if "$@"; then
        echo -e "${GREEN}OK: ${title}${RESET}"
    else
        echo -e "${RED}FAILED: ${title} (continuing)${RESET}"
    fi
    echo
}

stop_app_platform() {
    [ -d app_platform ] || { echo "app_platform directory not found; skipping."; return 0; }
    (cd app_platform && sudo docker compose down --remove-orphans)
}

stop_raspap() {
    [ -f docker-compose.raspap.yml ] || { echo "docker-compose.raspap.yml not found; skipping."; return 0; }
    sudo docker compose -f docker-compose.raspap.yml down
}

remove_kiosk_autostart() {
    if [ -f uninstallAutostartKiosk.sh ]; then
        sudo bash uninstallAutostartKiosk.sh
    else
        echo "uninstallAutostartKiosk.sh not found; skipping."
    fi
}

remove_vc_mipi_driver() {
    PACKAGE_NAME="vc-mipi-driver-bcm2712"
    if dpkg -l | grep -q "^ii  ${PACKAGE_NAME}"; then
        sudo apt-get remove -y "${PACKAGE_NAME}"
    else
        echo "${PACKAGE_NAME} is not installed; skipping."
    fi
}

remove_vc_mipi_boot_config() {
    local f="/boot/firmware/config_vc-mipi-driver-bcm2712.txt"
    if [ -f "$f" ]; then
        sudo rm -f "$f"
    else
        echo "$f not present; skipping."
    fi
}

remove_build_info() {
    local f="app_platform/var/build_info.json"
    if [ -f "$f" ]; then
        rm -f "$f"
    else
        echo "$f not present; skipping."
    fi
}

remove_installer_logs() {
    local logdir="$HOME/.platform_installer_logs"
    if [ -d "$logdir" ]; then
        rm -rf "$logdir"
    fi
    rm -f "$HOME"/platform_install_logs_*.tar.gz
    if [ -d /var/log/platform-installer ]; then
        sudo rm -rf /var/log/platform-installer
    fi
}

run_step "Stop app platform services" stop_app_platform
run_step "Stop raspap services" stop_raspap
run_step "Remove Firefox kiosk autostart" remove_kiosk_autostart
run_step "Remove vc-mipi-driver package" remove_vc_mipi_driver
run_step "Remove vc-mipi-driver boot config" remove_vc_mipi_boot_config
run_step "Remove build metadata" remove_build_info
run_step "Remove installer logs" remove_installer_logs

echo "Uninstall complete."
echo "Note: Docker, apt packages (netplan.io, gh, p7zip-full), netplan/Avahi/nftables"
echo "network config, WLAN country, and the rfkill mask were left in place."
