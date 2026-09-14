# goss test suite for install.sh (platform-builder)
#
# Verifies the end state that install.sh is supposed to produce. Run it on a
# box that has already been through `bash install.sh` at least once.
#
# Usage (run as root, or a user with passwordless sudo, from the repo root
# so relative paths like `app_platform/` resolve the same way install.sh
# assumes them):
#   curl -fsSL https://goss.rocks/install | sh
#   cd /home/raspberrypi/platform-builder
#   sudo goss validate
#
# Notes:
#   - kernel-param / mount / most of /etc,/boot file checks need root.
#   - Container names for `docker compose ps` are looked up by service name
#     via `--services`, not hardcoded container names, since the exact
#     container name depends on the compose project name.