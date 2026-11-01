#!/bin/bash
# Installs or updates the platform: clones/updates ~/platform-builder to the
# latest commit of $branch (or the git tag/ref given as first argument) and runs
# install.sh.
#
# Device data (settings, users, .env, local overrides, history CSV) is not in
# git - the repo only has defaults in app_platform/defaults/. It is backed up to
# $DEVICE_BACKUP before the git operations and restored afterwards, so neither
# the reset nor a version that still tracked these files (the checkout deletes
# them) loses it.
branch="feat/siemens2"
version="${1:-}" # optional git tag/ref; defaults to latest commit on $branch
user=$(whoami)
MIN_FREE_MB=500
REPO_URL="https://github.com/Notavis-GmbH/platform-builder"
DEVICE_BACKUP="/opt/platform-builder/device-backup"
DEVICE_FILES=(
  app_platform/.env
  app_platform/docker-compose.override.yml
  app_platform/frpc/frpc.local.toml
  app_platform/settings/backendSettings.json
  app_platform/settings/cameraSettings.json
  app_platform/settings/runtimeSettings.json
  app_platform/settings/settings.json
  app_platform/settings/siemenssternSettings.json
  app_platform/settings/users.json
  app_platform/settings/customer_logo.png
  app_platform/ftp/ftpsettings.json
  app_platform/ftp/status.json
  app_platform/history_images/app.csv
)

die() {
  echo "ERROR: $*" >&2
  exit 1
}

check_disk_space() {
  local path="$1"
  local avail_mb
  avail_mb=$(df --output=avail -BM "$path" 2>/dev/null | tail -1 | tr -dc '0-9')
  if [ -z "$avail_mb" ] || [ "$avail_mb" -lt "$MIN_FREE_MB" ]; then
    die "Not enough disk space on $path (${avail_mb:-0}MB available, need at least ${MIN_FREE_MB}MB free). Aborting installation before touching the repo."
  fi
}

# Copies the existing device files (relative paths) to $DEVICE_BACKUP
backup_device_files() {
  local f
  for f in "${DEVICE_FILES[@]}"; do
    if [ -f "$f" ]; then
      mkdir -p "$DEVICE_BACKUP/$(dirname "$f")" && cp -p "$f" "$DEVICE_BACKUP/$f" ||
        die "Could not back up $f to $DEVICE_BACKUP - nothing was changed."
    fi
  done
  echo "Device files backed up to $DEVICE_BACKUP"
}

# Puts the backed up device files back (after the checkout)
restore_device_files() {
  local f
  for f in "${DEVICE_FILES[@]}"; do
    if [ -f "$DEVICE_BACKUP/$f" ]; then
      mkdir -p "$(dirname "$f")" && cp -p "$DEVICE_BACKUP/$f" "$f" || echo "WARNING: could not restore $f" >&2
    fi
  done
  echo "Device files restored"
}

# Keep running when the terminal goes away (e.g. the ttyd web console is
# restarted by the update), install.sh writes its logs to files
trap '' HUP

# Ask for the sudo password once, keep the sudo timestamp alive meanwhile
sudo -v || sudo -n true || die "sudo authentication failed."
( while kill -0 "$$" 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 60; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT

cd ~ || die "No home directory"
check_disk_space ~
sudo mkdir -p /opt/platform-builder && sudo chown "$user:$user" /opt/platform-builder || die "Could not create /opt/platform-builder"

if [ -d platform-builder ]; then
  if [ -d platform-builder/app_platform/license ]; then
    sudo mkdir -p /opt/platform-builder/license
    sudo chown $user:$user -R /opt/platform-builder/
    sudo chmod 755 -R /opt/platform-builder/
    cp -r platform-builder/app_platform/license /opt/platform-builder/
  fi
  sudo chown -R "$user:$user" ~/platform-builder # ensure user owns the dir
  cd platform-builder || die "Cannot enter ~/platform-builder"

  backup_device_files
  git fetch origin --tags || die "git fetch failed (network?) - nothing was changed, still on $(git rev-parse --short HEAD)."
  if [ -n "$version" ]; then
    target=$(git rev-parse --verify --quiet "${version}^{commit}") || die "Version $version not found - nothing was changed."
  else
    target=$(git rev-parse --verify --quiet "origin/$branch^{commit}") || die "Branch $branch not found on origin - nothing was changed."
  fi

  # Discard local changes of tracked files, switch, then clean up untracked
  # files with the .gitignore of the new version
  git reset --hard -q || die "git reset failed"
  if [ -n "$version" ]; then
    git checkout -q "$target" || die "git checkout $version failed"
  else
    git checkout -q -B "$branch" "$target" || die "git checkout $branch failed"
  fi
  git clean -fdq
  restore_device_files
else
  git clone "$REPO_URL" platform-builder || die "git clone failed"
  cd platform-builder || die "Cannot enter ~/platform-builder"
  if [ -n "$version" ]; then
    git checkout -q "$version" || die "Version $version not found"
  else
    git checkout -q -B "$branch" "origin/$branch" || die "Branch $branch not found"
  fi
fi
echo "Installing $(git rev-parse --short HEAD) ($(git log -1 --format=%s | cut -c1-60))"

if [ "${SELFINSTALLER_SKIP_INSTALL:-0}" = "1" ]; then
  echo "SELFINSTALLER_SKIP_INSTALL=1 - repo updated, install.sh not run"
  exit 0
fi
bash install.sh
rc=$?
[ $rc -eq 0 ] || echo "ERROR: install.sh reported failed steps (exit $rc), see the log above." >&2
exit $rc
