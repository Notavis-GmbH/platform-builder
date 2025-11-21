# Platform Builder

## Install
```shell
if [ -d platform-builder ]; then \
  cd platform-builder && git reset --hard HEAD && git clean -fd && git pull && bash install.sh; \
else \
  git clone https://github.com/Notavis-GmbH/platform-builder && cd platform-builder && bash install.sh; \
fi
```
