#!/bin/bash
# Builds m2m_encoder (isp_raspi4) on the Pi and packs it into a camera image
# based on the running cam_v4l2 image - only /app/m2m_encoder is replaced.
# The full image build (docker/Dockerfile.build.arm64) compiles libcamera and
# libpisp from source, too heavy for the Pi; libcamera headers/libs are taken
# from the base camera image instead (same version the binary runs against).
# Compiles with 1 job (2 jobs ran out of memory) and kills the build when MemAvailable < MIN_AVAIL_MB.
# Usage: build_camera.sh <isp_raspi4 dir> <new image tag> [log file]
set -u
SRC=$(realpath "${1:?isp_raspi4 dir}")/src
TAG=${2:?image tag, e.g. reg.fls-engineering.de/library/cam_v4l2:3.0.1-latency}
LOG=${3:-/tmp/build_camera.log}
BASE_IMAGE=registry.fls-engineering.de/baseimage:arm64
CAM_IMAGE=reg.fls-engineering.de/library/cam_v4l2:3.0.0
WORK=/mnt/ssd/build/cam-build
NAME=latency-cam-build
MIN_AVAIL_MB=400

: > "$LOG"
# Remains of an earlier run may belong to root (build container)
[ -d "$WORK" ] && docker run --rm -v "$(dirname "$WORK")":/w "$BASE_IMAGE" rm -rf "/w/$(basename "$WORK")"
mkdir -p "$WORK/deps/lib" "$WORK/out" || exit 1

# libcamera/libpisp of the camera image
cid=$(docker create "$CAM_IMAGE")
docker cp "$cid:/usr/include/libcamera" "$WORK/deps/libcamera"
for f in libcamera-base.so libcamera-base.so.0.7 libcamera-base.so.0.7.0 libcamera.so libcamera.so.0.7 \
         libcamera.so.0.7.0 libpisp.so libpisp.so.1 libpisp.so.1.7.0; do
  docker cp "$cid:/usr/lib/aarch64-linux-gnu/$f" "$WORK/deps/lib/"
done
docker rm "$cid" >/dev/null
cat > "$WORK/deps/libcamera.pc" <<'EOF'
prefix=/usr
Name: libcamera
Description: libcamera of the cam_v4l2 image
Version: 0.7.0
Libs: -L/usr/lib/aarch64-linux-gnu -lcamera -lcamera-base
Cflags: -I/usr/include
EOF

docker rm -f $NAME >/dev/null 2>&1
docker run -d --name $NAME --oom-score-adj=1000 -e OWNER="$(id -u):$(id -g)" \
  -v "$SRC":/src:ro -v "$WORK":/work "$BASE_IMAGE" sh -c '
    set -e
    # Compile inside the container, only the binary goes back to /work
    apt-get update -qq && apt-get install -y -qq --no-install-recommends meson v4l-utils libv4l-dev \
      nlohmann-json3-dev libevent-dev libssl-dev python3-dev >/dev/null
    cp -r /work/deps/libcamera /usr/include/libcamera
    cp -a /work/deps/lib/. /usr/lib/aarch64-linux-gnu/
    cp /work/deps/libcamera.pc /usr/lib/aarch64-linux-gnu/pkgconfig/
    cp -r /src /tmp/src && mkdir /tmp/src/buildtest && cd /tmp/src/buildtest
    cmake -GNinja -DCMAKE_BUILD_TYPE=Debug -DENABLE_TESTING=OFF .. 2>&1 | tail -40
    ninja -j1
    cp bin/m2m_encoder /work/out/ && chown "$OWNER" /work/out/m2m_encoder' >/dev/null

min=999999
while [ "$(docker inspect -f '{{.State.Running}}' $NAME 2>/dev/null)" = "true" ]; do
  avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
  [ "$avail" -lt "$min" ] && min=$avail
  if [ "$avail" -lt "$MIN_AVAIL_MB" ]; then
    echo "GUARD: MemAvailable ${avail} MB < ${MIN_AVAIL_MB} MB, killing build" >> "$LOG"
    docker kill $NAME >/dev/null
    break
  fi
  sleep 0.5
done
docker logs $NAME >> "$LOG" 2>&1
code=$(docker inspect -f '{{.State.ExitCode}}' $NAME)
docker rm $NAME >/dev/null
echo "compile exit $code, min MemAvailable ${min} MB" >> "$LOG"
[ "$code" = "0" ] && [ -f "$WORK/out/m2m_encoder" ] || exit 1

# Image: running camera image with the new binary
cat > "$WORK/out/Dockerfile" <<EOF
FROM $CAM_IMAGE
COPY m2m_encoder /app/m2m_encoder
EOF
docker build -q -t "$TAG" "$WORK/out" >> "$LOG" 2>&1 || exit 1
# All libraries of the new binary must resolve in the camera image
if docker run --rm --entrypoint sh "$TAG" -c 'ldd /app/m2m_encoder' | grep "not found" >> "$LOG"; then
  echo "missing libraries in $TAG" >> "$LOG"
  exit 1
fi
echo "image $TAG built" >> "$LOG"
