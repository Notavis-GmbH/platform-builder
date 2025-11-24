#!/bin/bash


cd /home/raspberrypi/
if [ -d platform-builder ]; then 
  if [ -f platform-builder/app_platform/license ]; then 
    sudo mkdir -p /opt/platform-builder/
    sudo chown pi:pi /opt/platform-builder/
    sudo chmod 755 -R /opt/platform-builder/
    scp -r  platform-builder/app_platform/license /opt/platform-builder/ 
  fi
  cd platform-builder  && bash install.sh

#   cd platform-builder && git reset --hard HEAD && git clean -fd && git pull && bash install.sh
else 
  git clone https://github.com/Notavis-GmbH/platform-builder && cd platform-builder && bash install.sh
fi