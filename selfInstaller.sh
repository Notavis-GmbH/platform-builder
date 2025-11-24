#!/bin/bash
user=$(whoami)
cd  ~
if [ -d platform-builder ]; then 
  if [ -d platform-builder/app_platform/license ]; then 
    sudo mkdir -p /opt/platform-builder/license
    sudo chown $user:$user -R /opt/platform-builder/
    sudo chmod 755 -R /opt/platform-builder/
    scp -r  platform-builder/app_platform/license /opt/platform-builder/ 
  fi
    cd platform-builder && git reset --hard HEAD && git clean -fd &&  git pull  && git switch master && bash install.sh
else 
  git clone https://github.com/Notavis-GmbH/platform-builder && cd platform-builder && bash install.sh
fi


