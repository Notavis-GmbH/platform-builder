#!/bin/bash

if [ "$(id -u)" -eq 0 ]; then
  echo "Do not run this script as root. Run as a normal user (sudo is used where required)." >&2
  exit 1
fi

echo "Starting platform installation..."

# Keep running when the terminal goes away (e.g. the ttyd web console is
# restarted by the update), the steps write their output to log files
trap '' HUP

# Ask for the sudo password once up front, then keep the sudo timestamp alive
# so long-running steps never prompt again (prompts inside steps are hidden by the spinner)
sudo -v || sudo -n true || { echo "sudo authentication failed." >&2; exit 1; }
( while kill -0 "$$" 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 60; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT

# directory for per-step logs, only of this run
LOGDIR="$HOME/.platform_installer_logs"
mkdir -p "$LOGDIR"
rm -f "$LOGDIR"/*.log
FAILED_STEPS=()

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
        FAILED_STEPS+=("Step ${STEP_NO}: ${title}")
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
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local dkms_postinst="/usr/lib/dkms/common.postinst"
    local backup="${dkms_postinst}.pre-vc-mipi-force.bak"

    # Use the .deb shipped with the repo if present, otherwise download it
    if [ -f "${script_dir}/${deb}" ]; then
        echo "Found ${deb} in repository, installing from local file."
        deb="${script_dir}/${deb}"
    else
        echo "${deb} not found locally, downloading from GitHub."
        wget -N --timestamping "https://github.com/VC-MIPI-modules/vc_mipi_raspi/releases/download/v${version}/${deb}" || return 1
        deb="./${deb}"
    fi

    sudo cp "$dkms_postinst" "$backup"
    sudo sed -i 's/dkms install -m "$NAME" -v "$VERSION" -k "$KERNEL" ${ARCH:+-a "$ARCH"}$/&  --force/' "$dkms_postinst"

    local rc=0
    sudo apt install "${deb}" -y "$@" || rc=$?

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
REQUIRED_VERSION="0.8.0"
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

# The driver package's postinst overwrites this file with its defaults, so always copy ours afterwards
echo "Step 7: Copying vc-mipi-driver config to /boot/firmware/..."
run_step "Copy vc-mipi-driver config" "sudo cp resources/config_vc-mipi-driver-bcm2712.txt /boot/firmware/"

echo "Step 7a: Copying vc-mipi camera overlays to /boot/firmware/overlays/..."
run_step "Copy vc-mipi camera overlays" "sudo cp vc-mipi-bcm2712-cam0.dtbo vc-mipi-bcm2712-cam1.dtbo /boot/firmware/overlays/"

echo "Step 7b: Installing camera IRQ affinity service..."
run_step "Install camera IRQ affinity" "bash installCameraIrqAffinity.sh"

echo "Step 7b2: Installing CSI-2 pad format alignment service..."
run_step "Install CSI pipeline format" "bash installCsiPipelineFormat.sh"

# Root cause found 2026-08-12 on UniversitySidney2 with drop-hunt sampler: default
# writeback thresholds let 400-800 MB of dirty pages accumulate before flushing,
# causing 1.8-2.7 s I/O stalls that drop frames during continuous BMP capture at
# 60 fps. Lowering the thresholds flushes dirty pages sooner and in smaller bursts.
install_writeback_sysctl() {
    local src="resources/99-notavis-writeback.conf"
    local dst="/etc/sysctl.d/99-notavis-writeback.conf"

    if [ ! -f "$src" ]; then
        echo "${src} not found; skipping writeback sysctl config." >&2
        return 1
    fi

    sudo cp "$src" "$dst" && sudo sysctl --system
}

echo "Step 7c: Configuring writeback tuning to prevent capture drops..."
run_step "Configure writeback sysctl tuning" -- install_writeback_sysctl

# Add log limit to 10 mb for docker globally
echo "Step 8: Configuring Docker logging..."
run_step "Configure Docker logging" "mkdir -p ~/.docker/ && cp resources/config.json ~/.docker/config.json"

echo "Step 9: Starting raspap services..."
run_step "Start raspap services" "sudo docker compose -f docker-compose.raspap.yml up -d"

echo "Step 10: Starting app platform services..."

# Device data is not in git (see selfInstaller.sh): create the missing files
# from app_platform/defaults/ - existing ones are never overwritten. Must run
# before the services start: docker creates a directory for a missing
# bind-mounted file.
ensure_device_files() {
    local f target
    while IFS= read -r f; do
        target="app_platform/${f#./}"
        if [ -d "$target" ] && [ -z "$(ls -A "$target")" ]; then
            rmdir "$target" || sudo rmdir "$target"   # empty dir created by docker for a missing file
        fi
        if [ ! -e "$target" ]; then
            mkdir -p "$(dirname "$target")"
            cp -p "app_platform/defaults/${f#./}" "$target"
            echo "created $target from defaults"
        fi
    done < <(cd app_platform/defaults && find . -type f)
}
run_step "Create missing device files from defaults" -- ensure_device_files

# Compose file of the app platform, used for pull/up, the space check and the
# build metadata
APP_COMPOSE_FILE="app_platform/docker-compose.siemens.yml"
# Device-specific settings (not in git, so the git reset of selfInstaller.sh
# keeps them) go into app_platform/docker-compose.override.yml, loaded on top
# of the compose file. Arguments relative to app_platform/.
APP_COMPOSE_ARGS="-f $(basename "$APP_COMPOSE_FILE")"
if [ -f app_platform/docker-compose.override.yml ]; then
    APP_COMPOSE_ARGS="$APP_COMPOSE_ARGS -f docker-compose.override.yml"
    echo "Using device overrides: app_platform/docker-compose.override.yml"
fi
app_compose() {
    (cd app_platform && sudo docker compose $APP_COMPOSE_ARGS "$@")
}

# Remove images no container uses (old tags after an update, test images) and
# the build cache. Images of stopped containers are kept.
prune_unused_images() {
    sudo docker image prune -af
    sudo docker builder prune -af
    df -h /var/lib/containerd /var/lib/docker 2>/dev/null
}

# Before the pull: remove only images that no container uses and that the
# compose files do not reference either - a referenced image without a
# container (e.g. after a manual test) would otherwise be pulled again.
prune_images_before_pull() {
    local id ref
    # Compared by image ID: containers of locally built images (ttyd) only
    # show the ID, compose lists them without the :latest tag
    mapfile -t keep < <(
        sudo docker ps -aq | xargs -r sudo docker inspect --format '{{.Image}}'
        {
            app_compose config --images 2>/dev/null
            sudo docker compose -f docker-compose.raspap.yml config --images 2>/dev/null
        } | xargs -r -n1 sudo docker image inspect --format '{{.Id}}' 2>/dev/null
    )
    while read -r id ref; do
        if ! printf '%s\n' "${keep[@]}" | grep -qxF "$id"; then
            echo "removing $ref"
            sudo docker rmi "$ref"
        fi
    done < <(sudo docker images --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}}' | grep -v '<none>')
    sudo docker image prune -f
    sudo docker builder prune -af
    df -h /var/lib/containerd /var/lib/docker 2>/dev/null
}

# Abort before pulling if the images that are not on the device yet would not
# fit: a new tag of a big image (backend ~1.5 GB) is pulled while the old one
# is still in use, both are on the disk until the cleanup after the start.
# Needed space per missing image: compressed size from the registry x 4
# (compressed blobs + unpacked layers, measured 3.7x for backend 2.6.0),
# plus IMAGE_SPACE_RESERVE_MB for the system. SKIP_IMAGE_SPACE_CHECK=1 skips it.
IMAGE_SPACE_FACTOR=4
IMAGE_SPACE_RESERVE_MB=500
check_image_space() {
    if [ "${SKIP_IMAGE_SPACE_CHECK:-0}" = "1" ]; then
        echo "SKIP_IMAGE_SPACE_CHECK=1 - skipping the check"
        return 0
    fi
    local arch needed_mb=0 img size_mb avail_mb store
    arch=$(sudo docker info --format '{{.Architecture}}' 2>/dev/null)
    case "$arch" in aarch64) arch=arm64 ;; x86_64) arch=amd64 ;; esac

    mapfile -t images < <(app_compose config --images 2>/dev/null | sort -u)
    for img in "${images[@]}"; do
        if sudo docker image inspect "$img" >/dev/null 2>&1; then
            continue
        fi
        # compressed size of the layers for this architecture (image index or single manifest)
        size_mb=$(sudo docker manifest inspect -v "$img" 2>/dev/null | python3 -c '
import json, sys
arch = sys.argv[1]
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for entry in data if isinstance(data, list) else [data]:
    platform = entry.get("Descriptor", {}).get("platform", {})
    if platform.get("architecture", arch) != arch:
        continue
    manifest = entry.get("OCIManifest") or entry.get("SchemaV2Manifest") or {}
    print(sum(layer["size"] for layer in manifest.get("layers", [])) // 1000000)
    break
' "$arch")
        if [ -z "$size_mb" ]; then
            echo "WARNING: size of $img unknown (built locally or registry not reachable), not counted"
            continue
        fi
        echo "missing: $img (${size_mb} MB compressed, ~$((size_mb * IMAGE_SPACE_FACTOR)) MB on disk)"
        needed_mb=$((needed_mb + size_mb * IMAGE_SPACE_FACTOR))
    done

    # The image store of the containerd snapshotter, older setups use /var/lib/docker
    store=/var/lib/containerd
    [ -d "$store" ] || store=/var/lib/docker
    avail_mb=$(df --output=avail -BM "$store" | tail -1 | tr -dc '0-9')
    needed_mb=$((needed_mb + IMAGE_SPACE_RESERVE_MB))
    echo "needed: ${needed_mb} MB (incl. ${IMAGE_SPACE_RESERVE_MB} MB reserve), available on $store: ${avail_mb} MB"
    if [ "$avail_mb" -lt "$needed_mb" ]; then
        echo "ERROR: not enough disk space for the new images. Free $((needed_mb - avail_mb)) MB" \
             "(e.g. history images in app_platform/history_images) or set SKIP_IMAGE_SPACE_CHECK=1." >&2
        return 1
    fi
}

run_step "Remove unused docker images" -- prune_images_before_pull
if ! run_step "Check disk space for new images" -- check_image_space; then
    echo -e "${RED}Aborting: not enough disk space for the new images, the running services were not changed.${RESET}"
    exit 1
fi
run_step "Pull app platform images" "cd app_platform && sudo docker compose $APP_COMPOSE_ARGS pull"
run_step "Start app platform services" "cd app_platform && sudo docker compose $APP_COMPOSE_ARGS up -d --remove-orphans"
# The old versions of updated images are no longer used by any container now
run_step "Remove old docker images" -- prune_unused_images

# echo "Step 10: Uninstalling autostart kiosk..."
# run_step "Uninstall autostart kiosk" "sudo bash uninstallAutostartKiosk.sh"

# Archive installer logs and copy to /var/log/platform-installer for diagnostics
archive_installer_logs() {
    TS=$(date +%Y%m%d-%H%M%S)
    TAR="$HOME/platform_install_logs_${TS}.tar.gz"
    if [ -d "$LOGDIR" ]; then
        tar -czf "$TAR" -C "$LOGDIR" .
        sudo mkdir -p /var/log/platform-installer
        sudo cp "$TAR" /var/log/platform-installer/
        echo "Archived installer logs to $TAR and copied to /var/log/platform-installer/"
        # keep the last 5 archives in the home directory
        ls -1t "$HOME"/platform_install_logs_*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f
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
    # the compose file the services are started with (see Step 10)
    compose_file="$APP_COMPOSE_FILE"
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

if [ ${#FAILED_STEPS[@]} -eq 0 ]; then
    echo -e "${GREEN}${CHECK_MARK} Platform installation completed successfully!${RESET}"
else
    echo -e "${RED}${CROSS_MARK} Platform installation finished with ${#FAILED_STEPS[@]} failed step(s):${RESET}"
    printf '  %s\n' "${FAILED_STEPS[@]}"
    echo "Logs: $LOGDIR"
    exit 1
fi