#!/bin/bash
# Builds siemensstern_analyzer_service (siemensstern-calibration/cpp) on the Pi
# and packs it into an image based on the running siemensstern image - only
# /app/siemensstern_analyzer_service is replaced. Release build like
# docker/Dockerfile.arm64, only the service target, 1 job, killed when
# MemAvailable < MIN_AVAIL_MB. The libraries of the base image the binary
# links from /usr/local/lib (OpenCV) are added to the image.
# Usage: build_siemens.sh <siemensstern-calibration dir> <new image tag> [log file]
set -u
SRC=$(realpath "${1:?siemensstern-calibration dir}")/cpp
TAG=${2:?image tag, e.g. reg.fls-engineering.de/library/siemensstern:1.3.0}
LOG=${3:-/tmp/build_siemens.log}
BASE_IMAGE=registry.fls-engineering.de/baseimage:arm64
APP_IMAGE=reg.fls-engineering.de/library/siemensstern:1.2.0
WORK=/mnt/ssd/build/siemens-build
NAME=latency-siemens-build
MIN_AVAIL_MB=400

: > "$LOG"
[ -d "$WORK" ] && docker run --rm -v "$(dirname "$WORK")":/w "$BASE_IMAGE" rm -rf "/w/$(basename "$WORK")"
mkdir -p "$WORK/out" || exit 1

docker rm -f $NAME >/dev/null 2>&1
docker run -d --name $NAME --oom-score-adj=1000 -e OWNER="$(id -u):$(id -g)" \
  -v "$SRC":/src:ro -v "$WORK":/work "$BASE_IMAGE" sh -c '
    set -e
    apt-get update -qq && apt-get install -y -qq --no-install-recommends meson v4l-utils libv4l-dev \
      nlohmann-json3-dev libssl-dev python3-dev >/dev/null
    cp -r /src /tmp/cpp && mkdir /tmp/cpp/build && cd /tmp/cpp/build
    cmake -GNinja -DCMAKE_BUILD_TYPE=Release -DENABLE_TESTING=OFF .. 2>&1 | tail -20
    ninja -j1 siemensstern_analyzer_service
    cp app/siemensstern_analyzer_service /work/out/
    # Libraries from /usr/local/lib (OpenCV etc. of the base image) the runtime
    # image may not have in this version - like docker/exportDepends.sh
    mkdir -p /work/out/lib
    for f in $(ldd app/siemensstern_analyzer_service | awk "\$3 ~ /^\/usr\/local\/lib\// {print \$3}"); do
      cp -L "$f" /work/out/lib/
    done
    ls /work/out/lib
    chown -R "$OWNER" /work/out' >/dev/null

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
[ "$code" = "0" ] && [ -f "$WORK/out/siemensstern_analyzer_service" ] || exit 1

cat > "$WORK/out/Dockerfile" <<EOF
FROM $APP_IMAGE
COPY lib/ /usr/local/lib/
COPY siemensstern_analyzer_service /app/siemensstern_analyzer_service
EOF
docker build -q -t "$TAG" "$WORK/out" >> "$LOG" 2>&1 || exit 1
if docker run --rm --entrypoint sh "$TAG" -c 'ldd /app/siemensstern_analyzer_service' | grep "not found" >> "$LOG"; then
  echo "missing libraries in $TAG" >> "$LOG"
  exit 1
fi
echo "image $TAG built" >> "$LOG"
