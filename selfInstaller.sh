#!/bin/bash
branch="ov9281"
user=$(whoami)
MIN_FREE_MB=500

check_disk_space() {
  local path="$1"
  local avail_mb
  avail_mb=$(df --output=avail -BM "$path" 2>/dev/null | tail -1 | tr -dc '0-9')
  if [ -z "$avail_mb" ] || [ "$avail_mb" -lt "$MIN_FREE_MB" ]; then
    echo "ERROR: Not enough disk space on $path (${avail_mb:-0}MB available, need at least ${MIN_FREE_MB}MB free). Aborting installation before touching the repo." >&2
    exit 1
  fi
}

cd  ~
check_disk_space ~
if [ -d platform-builder ]; then
  if [ -d platform-builder/app_platform/license ]; then
    sudo mkdir -p /opt/platform-builder/license
    sudo chown $user:$user -R /opt/platform-builder/
    sudo chmod 755 -R /opt/platform-builder/
    scp -r  platform-builder/app_platform/license /opt/platform-builder/
  fi
    sudo chown -R "$(whoami):$(whoami)" ~/platform-builder # ensure user owns the dir
    cd platform-builder && git fetch origin && git reset --hard HEAD && git clean -fd && git checkout -B $branch origin/$branch && git pull && bash install.sh
else
  git clone https://github.com/Notavis-GmbH/platform-builder && cd platform-builder && git checkout -B $branch origin/$branch && git pull && bash install.sh
fi
