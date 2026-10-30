#!/bin/bash
# Builds notavis-frontend on the Pi without risking the running services:
# node:20 container, esbuild builder (switched only in a temp copy of the
# project, the repo's angular.json stays unchanged), one worker, and a guard
# that kills the build when MemAvailable drops below MIN_AVAIL_MB. The plain
# webpack build needs ~2 GB and made the Pi hang (2026-10-30).
# Usage: build_frontend.sh [project dir] [log file]
# Result: <project>/dist/opticus-frontend, deploy by copying it into
# app_platform/static_files/.
PROJECT=${1:-$(dirname "$0")/../../notavis-frontend}
PROJECT=$(realpath "$PROJECT")
LOG=${2:-/tmp/build_frontend.log}
NAME=latency-ng-build
MIN_AVAIL_MB=400

: > "$LOG"
docker rm -f $NAME >/dev/null 2>&1
docker run -d --name $NAME --oom-score-adj=1000 -u "$(id -u):$(id -g)" \
  -e HOME=/tmp -e NG_CLI_ANALYTICS=false -e NG_BUILD_MAX_WORKERS=1 \
  -e NODE_OPTIONS=--max-old-space-size=1024 \
  -v "$PROJECT":/src -w /src node:20 sh -c '
    [ -d /src/node_modules ] || npm ci --no-audit --no-fund --loglevel=error || exit 1
    mkdir /tmp/b && cp -r /src/src /src/angular.json /src/tsconfig.json /src/tsconfig.app.json /src/package.json /tmp/b/ &&
    ln -s /src/node_modules /tmp/b/node_modules && cd /tmp/b &&
    sed -i "s#build-angular:browser\"#build-angular:browser-esbuild\"#" angular.json &&
    npx ng build --configuration production && rm -rf /src/dist && cp -r dist /src/dist' >/dev/null

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
echo "exit $code, min MemAvailable ${min} MB" >> "$LOG"
docker rm $NAME >/dev/null
exit "$code"
