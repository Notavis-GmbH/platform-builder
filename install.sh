#!/bin/bash

if [ "$(id -u)" -eq 0 ]; then
  echo "Do not run this script as root. Run as a normal user (sudo is used where required)." >&2
  exit 1
fi

echo "Starting platform installation..."

# directory for per-step logs
LOGDIR="$HOME/.platform_installer_logs"
mkdir -p "$LOGDIR"

echo "Git branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown), commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)" | tee "$LOGDIR/git_info.log"

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
    wait "$cmd_pid" 2>/dev/null
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

# Configure Avahi to only listen on the bridge interface 'end0'
configure_avahi() {
    TS=$(date +%Y%m%d-%H%M%S)
    sudo cp /etc/avahi/avahi-daemon.conf /etc/avahi/avahi-daemon.conf."$TS".bak
    # If any allow-interfaces line exists (commented or not), replace it
    if sudo grep -q '^[[:space:]]*#\?[[:space:]]*allow-interfaces=' /etc/avahi/avahi-daemon.conf; then
        sudo sed -i 's/^[[:space:]]*#\?[[:space:]]*allow-interfaces=.*/allow-interfaces=end0/' /etc/avahi/avahi-daemon.conf
    else
        # Use awk to insert the setting immediately after the first [server] header.
        # If no [server] section exists, append a new section at EOF.
        sudo awk '
            BEGIN{added=0}
            /^\[server\]/{print; print "allow-interfaces=end0"; added=1; next}
            {print}
            END{if(!added){print "\n[server]"; print "allow-interfaces=end0"}}' /etc/avahi/avahi-daemon.conf | sudo tee /etc/avahi/avahi-daemon.conf.tmp >/dev/null && sudo mv /etc/avahi/avahi-daemon.conf.tmp /etc/avahi/avahi-daemon.conf
    fi

    # Ensure Avahi is restarted to apply changes
    sudo systemctl restart avahi-daemon
}

run_step "Configure Avahi allowed interfaces" -- configure_avahi
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
        ip saddr 172.17.0.0/16 oifname != "docker0" masquerade
        ip saddr 172.18.0.0/16 oifname != "docker0" masquerade
        ip saddr 172.19.0.0/16 oifname != "docker0" masquerade
        ip saddr 192.168.0.0/16 oifname != "docker0" masquerade
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


# Vision Components' vc_mipi_* kernel modules sometimes ship built into the
# kernel image itself (under kernel/drivers/media/i2c/) at a newer version
# than this pinned DKMS package. DKMS then refuses "dkms install" because the
# module it's about to install isn't newer than what's already in the kernel
# tree ("is not newer than what is already found in kernel ..."). We
# temporarily patch dkms's shared postinst helper to force that one install,
# then restore the original helper so other DKMS packages keep the default
# safety check.
install_vc_mipi_driver() {
    local version="$1"
    shift
    local deb="vc-mipi-driver-bcm2712_${version}_arm64.deb"
    local dkms_postinst="/usr/lib/dkms/common.postinst"
    local backup="${dkms_postinst}.pre-vc-mipi-force.bak"

    wget -N --timestamping "https://github.com/VC-MIPI-modules/vc_mipi_raspi/releases/download/v${version}/${deb}" || return 1

    sudo cp "$dkms_postinst" "$backup"
    sudo sed -i 's/dkms install -m "$NAME" -v "$VERSION" -k "$KERNEL" ${ARCH:+-a "$ARCH"}$/&  --force/' "$dkms_postinst"

    local rc=0
    sudo apt install "./${deb}" -y "$@" || rc=$?

    sudo cp "$backup" "$dkms_postinst"
    sudo rm -f "$backup"

    return $rc
}

reconfigure_vc_mipi_driver_forced() {
    local dkms_postinst="/usr/lib/dkms/common.postinst"
    local backup="${dkms_postinst}.pre-vc-mipi-force.bak"

    sudo cp "$dkms_postinst" "$backup"
    sudo sed -i 's/dkms install -m "$NAME" -v "$VERSION" -k "$KERNEL" ${ARCH:+-a "$ARCH"}$/&  --force/' "$dkms_postinst"

    local rc=0
    sudo dpkg --configure -a || rc=$?

    sudo cp "$backup" "$dkms_postinst"
    sudo rm -f "$backup"

    return $rc
}

# Check if vc-mipi-driver-bcm2712 is already installed with the correct version
echo "Step 6: Checking and installing vc-mipi-driver..."
REQUIRED_VERSION="0.6.10"
PACKAGE_NAME="vc-mipi-driver-bcm2712"

if dpkg -l | grep -q "^ii  ${PACKAGE_NAME}"; then
    INSTALLED_VERSION=$(dpkg -l | grep "^ii  ${PACKAGE_NAME}" | awk '{print $3}')
    echo "Found ${PACKAGE_NAME} version ${INSTALLED_VERSION}"

    if [ "${INSTALLED_VERSION}" = "${REQUIRED_VERSION}" ]; then
        echo "${PACKAGE_NAME} version ${REQUIRED_VERSION} is already installed. Skipping installation."
    else
        echo "Installed version (${INSTALLED_VERSION}) does not match required version (${REQUIRED_VERSION}). Updating..."
        run_step "Install vc-mipi-driver (update)" -- install_vc_mipi_driver "${REQUIRED_VERSION}" --allow-downgrades
    fi
else
    echo "${PACKAGE_NAME} is not installed. Installing version ${REQUIRED_VERSION}..."
    run_step "Install vc-mipi-driver" -- install_vc_mipi_driver "${REQUIRED_VERSION}"
fi

# dpkg may have left the package half-configured from a previous failed run
# (e.g. this exact "not newer than kernel" DKMS error). Retry configuration
# with the same forced-install patch so the installer is idempotent.
if dpkg -l | grep -q "^iF  ${PACKAGE_NAME}"; then
    echo "${PACKAGE_NAME} is half-configured from a previous failed install. Retrying..."
    run_step "Reconfigure vc-mipi-driver (forced)" -- reconfigure_vc_mipi_driver_forced
fi

echo "Step 7: Copying vc-mipi-driver config to /boot/firmware/..."
run_step "Copy vc-mipi-driver config" "sudo cp config_vc-mipi-driver-bcm2712.txt /boot/firmware/"

echo "Step 7a: Copying vc-mipi camera overlays to /boot/firmware/overlays/..."
run_step "Copy vc-mipi camera overlays" "sudo cp vc-mipi-bcm2712-cam0.dtbo vc-mipi-bcm2712-cam1.dtbo /boot/firmware/overlays/"

echo "Step 7b: Installing camera IRQ affinity service..."
run_step "Install camera IRQ affinity" "bash installCameraIrqAffinity.sh"

# Add log limit to 10 mb for docker globally
echo "Step 8: Configuring Docker logging..."
run_step "Configure Docker logging" "mkdir -p ~/.docker/ && cp resources/config.json ~/.docker/config.json"

echo "Step 9: Starting raspap services..."
run_step "Start raspap services" "sudo docker compose -f docker-compose.raspap.yml up -d"

echo "Step 10: Starting app platform services..."

# Some RPi5 NVMe HATs let the SSD controller drop into an unrecoverable low-power
# state (D3cold) under PCIe ASPM/APST power management, which surfaces as
# "controller is down" resets and the filesystem being shut down mid-write.
# Disabling these power-saving features on the kernel command line prevents that.
# Requires a reboot to take effect.
configure_nvme_power_management() {
    local cmdline="/boot/firmware/cmdline.txt"
    local params="nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off"

    if [ ! -f "$cmdline" ]; then
        echo "${cmdline} not found; skipping NVMe power management config." >&2
        return 0
    fi

    local missing=()
    local p
    for p in $params; do
        grep -qw -- "$p" "$cmdline" || missing+=("$p")
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        echo "NVMe power management parameters already present in ${cmdline}."
        return 0
    fi

    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    sudo cp "$cmdline" "${cmdline}.${ts}.bak"

    local current
    current=$(cat "$cmdline")
    echo "${current} ${missing[*]}" | sudo tee "$cmdline" >/dev/null

    echo "Added NVMe power management parameters to ${cmdline}: ${missing[*]}"
    echo "A reboot is required for this change to take effect."
}

run_step "Configure NVMe power management" -- configure_nvme_power_management

# /mnt/data must be mounted to persistent storage (e.g. an SSD/NVMe) before the app
# platform starts, otherwise docker will silently create /mnt/data on the root
# filesystem instead. This step is optional/best-effort: it only acts when it finds
# exactly one unmounted NVMe partition and /mnt/data isn't already mounted or in
# /etc/fstab; otherwise it does nothing and leaves the manual-mount requirement below
# in place.
setup_nvme_data_mount() {
    local mnt="/mnt/data"

    if mountpoint -q "$mnt"; then
        echo "${mnt} is already mounted; nothing to do."
        return 0
    fi

    if grep -qE "^[^#][^[:space:]]*[[:space:]]+${mnt}[[:space:]]" /etc/fstab; then
        echo "${mnt} already has an /etc/fstab entry; attempting to mount it..."
        sudo mkdir -p "$mnt"
        sudo mount "$mnt"
        return $?
    fi

    # Candidates: NVMe partitions that aren't mounted anywhere, split into ones that
    # already have a filesystem and ones that are blank (no fstype, e.g. a fresh or
    # freshly-wiped SSD).
    local candidates=()
    local blank_candidates=()
    while read -r dev fstype mountpt; do
        [ -z "$mountpt" ] || continue
        if [ -n "$fstype" ]; then
            candidates+=("$dev")
        else
            blank_candidates+=("$dev")
        fi
    done < <(lsblk -rno PATH,FSTYPE,MOUNTPOINT | grep -E '^/dev/nvme[0-9]+n[0-9]+p[0-9]+ ')

    # If there's no already-formatted candidate but exactly one blank NVMe partition,
    # format it as ext4 so a fresh/wiped SSD can be provisioned without manual steps.
    if [ "${#candidates[@]}" -eq 0 ] && [ "${#blank_candidates[@]}" -eq 1 ]; then
        local blank_part="${blank_candidates[0]}"
        echo "Found unformatted NVMe partition ${blank_part}; formatting as ext4."
        if sudo mkfs.ext4 -F -L data "$blank_part"; then
            candidates=("$blank_part")
        else
            echo "Failed to format ${blank_part}; skipping NVMe auto-mount." >&2
            return 1
        fi
    elif [ "${#candidates[@]}" -eq 0 ] && [ "${#blank_candidates[@]}" -gt 1 ]; then
        echo "Multiple unformatted NVMe partitions found (${blank_candidates[*]}); skipping NVMe auto-mount (ambiguous, pick one manually)." >&2
        return 0
    fi

    if [ "${#candidates[@]}" -eq 0 ]; then
        echo "No unmounted NVMe partition found; skipping NVMe auto-mount."
        return 0
    fi
    if [ "${#candidates[@]}" -gt 1 ]; then
        echo "Multiple unmounted NVMe partitions found (${candidates[*]}); skipping NVMe auto-mount (ambiguous, pick one manually)." >&2
        return 0
    fi

    local part="${candidates[0]}" uuid fstype
    uuid=$(sudo blkid -s UUID -o value "$part")
    fstype=$(sudo blkid -s TYPE -o value "$part")

    if [ -z "$uuid" ] || [ -z "$fstype" ]; then
        echo "Could not determine UUID/filesystem for ${part}; skipping NVMe auto-mount." >&2
        return 0
    fi

    echo "Found unmounted NVMe partition ${part} (${fstype}, UUID=${uuid}); mounting at ${mnt}."

    if [ -d "$mnt" ] && [ -n "$(ls -A "$mnt" 2>/dev/null)" ]; then
        echo "Note: ${mnt} already has content on the root filesystem. It will be hidden" \
             "(not deleted) once the NVMe is mounted over it."
    fi

    sudo mkdir -p "$mnt"

    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    sudo cp /etc/fstab "/etc/fstab.${ts}.bak"
    echo "UUID=${uuid}  ${mnt}  ${fstype}  defaults,nofail  0  2" | sudo tee -a /etc/fstab >/dev/null

    sudo mount "$mnt"
}

run_step "Mount NVMe to /mnt/data (optional)" -- setup_nvme_data_mount

# If /mnt/data ended up mounted (whether just now or already), make sure the
# installing user owns it so app_platform can write to it without sudo.
ensure_mnt_data_ownership() {
    local mnt="/mnt/data"
    if ! mountpoint -q "$mnt"; then
        echo "${mnt} is not mounted; skipping ownership check."
        return 0
    fi

    local owner
    owner=$(stat -c '%U:%G' "$mnt")
    if [ "$owner" = "$(id -un):$(id -gn)" ]; then
        echo "${mnt} is already owned by $(id -un):$(id -gn)."
    else
        echo "${mnt} is owned by ${owner}; changing to $(id -un):$(id -gn)."
        sudo chown "$(id -u):$(id -g)" "$mnt"
    fi
    sudo chmod 755 "$mnt"
}

run_step "Ensure /mnt/data ownership" -- ensure_mnt_data_ownership

check_mnt_data_mounted() {
    if ! mountpoint -q /mnt/data; then
        echo "/mnt/data is not a mount point. Mount the SSD to /mnt/data before running this installer." >&2
        return 1
    fi
}

if ! run_step "Check /mnt/data is mounted" -- check_mnt_data_mounted; then
    echo "Aborting: /mnt/data must be mounted to persistent storage first. Mount the SSD, then re-run the installer." >&2
    exit 1
fi

run_step "Pull app platform images" "cd app_platform && sudo docker compose pull"
run_step "Start app platform services" "cd app_platform && sudo docker compose up -d --remove-orphans"

echo "Step 11: Uninstalling autostart kiosk..."
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

# Record git commit and docker image versions to a JSON file for FastAPI to read
record_build_info() {
    TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    # write into app_platform/var so the backend can mount/read it via ./var:/version_info
    BUILD_FILE="app_platform/var/build_info.json"
    mkdir -p "$(dirname "$BUILD_FILE")"

    GIT_COMMIT=$(git rev-parse --verify --short HEAD 2>/dev/null || echo "")
    GIT_FULL_COMMIT=$(git rev-parse --verify HEAD 2>/dev/null || echo "")
    GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    GIT_REMOTE=$(git config --get remote.origin.url 2>/dev/null || echo "")

    images_json="[]"
    compose_file="app_platform/docker-compose.yml"
    if [ -f "$compose_file" ]; then
        # extract image: lines (ignore commented lines) and trim quotes
        mapfile -t compose_images < <(
            grep -E '^[[:space:]]*image:' "$compose_file" \
            | sed -E 's/^[[:space:]]*image:[[:space:]]*//' \
            | sed "s/[\"']//g" \
            | sed 's/[[:space:]]*$//' \
            | sort -u
        )
    else
        compose_images=()
    fi

    if [ "${#compose_images[@]}" -ne 0 ]; then
        images_array=()
        if command -v docker >/dev/null 2>&1; then
            # get local images once (sudo: docker group membership from this session's
            # `usermod -aG docker` won't be active until re-login)
            mapfile -t local_lines < <(sudo docker images --format '{{.Repository}}:::{{.Tag}}:::{{.ID}}' | sort -u)
        else
            local_lines=()
        fi

        for img in "${compose_images[@]}"; do
            # normalize image (trim)
            img=$(printf '%s' "$img" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

            # parse repo and tag from the compose image string
            if echo "$img" | grep -q ':'; then
                repo="${img%:*}"
                tag="${img##*:}"
            else
                repo="$img"
                tag=""
            fi

            id=""
            present=false
            if command -v docker >/dev/null 2>&1; then
                # attempt to find local image by exact repo:tag match
                id=$(sudo docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | awk -v img="$img" '$1==img {print $2; exit}') || true
                if [ -n "$id" ]; then
                    present=true
                fi
            fi

            # escape values for JSON
            repo_esc=$(printf '%s' "$repo" | sed 's/"/\\"/g')
            tag_esc=$(printf '%s' "$tag" | sed 's/"/\\"/g')
            id_esc=$(printf '%s' "$id" | sed 's/"/\\"/g')
            present_flag=$([[ "$present" = true ]] && echo true || echo false)

            images_array+=("{\"image\":\"$(printf '%s' "$img" | sed 's/"/\\"/g')\",\"repository\":\"$repo_esc\",\"tag\":\"$tag_esc\",\"id\":\"$id_esc\",\"present_locally\":$present_flag}")
        done

        images_json=$(printf '[%s]' "$(IFS=,; echo "${images_array[*]}")")
    fi

    cat > "$BUILD_FILE" <<EOF
{
  "timestamp": "$TS",
  "git": {
    "commit": "$GIT_COMMIT",
    "commit_full": "$GIT_FULL_COMMIT",
    "branch": "$GIT_BRANCH",
    "remote": "$GIT_REMOTE"
  },
  "docker_images": $images_json
}
EOF

    echo "Wrote build info to $BUILD_FILE"
}


run_step "Install autostart kiosk service" "bash installAutostartKiosk.sh"

run_step "Record build metadata" -- record_build_info

echo "Platform installation completed successfully!"