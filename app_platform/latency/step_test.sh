#!/bin/bash
# Exposure step test: a socket.io client in the backend container logs the mean
# brightness of every live image, the sensor exposure is changed for 3 s and
# restored. The delay between the control write and the first image with the
# new brightness is the latency sensor -> socket.io output (incl. the 1-2
# frames the sensor needs to apply a new exposure).
# Usage: step_test.sh <exposure normal> <exposure step> [subdev]
set -eu
EXP=$1
STEP=$2
SUBDEV=${3:-/dev/v4l-subdev2}
PROBE=/tmp/latency_probe.py

cat > /tmp/latency_probe.py <<'EOF'
import asyncio, base64, json, sys, time
import cv2, numpy as np, socketio
sio = socketio.AsyncClient()
@sio.on('image')
async def on_image(data):
    t = time.time()
    msg = json.loads(data)
    img = cv2.imdecode(np.frombuffer(base64.b64decode(msg["image"]), np.uint8), cv2.IMREAD_GRAYSCALE)
    print(f"{t:.3f} {msg['counter']} {img.mean():.1f}", flush=True)
async def main():
    await sio.connect("http://localhost:8000", socketio_path="/ws/socket.io/", transports=["websocket"], wait_timeout=15)
    await sio.emit("activeCamera", 0)
    await asyncio.sleep(float(sys.argv[1]))
    await sio.disconnect()
asyncio.run(main())
EOF
docker exec -i app_platform-backend-1 sh -c "cat > $PROBE" < /tmp/latency_probe.py
docker exec app_platform-backend-1 timeout 30 python $PROBE 10 > /tmp/step.log 2>&1 &
trap 'v4l2-ctl -d "$SUBDEV" -c exposure="$EXP"' EXIT
sleep 3
t_step=$(date +%s.%N); v4l2-ctl -d "$SUBDEV" -c exposure="$STEP"
sleep 3
t_back=$(date +%s.%N); v4l2-ctl -d "$SUBDEV" -c exposure="$EXP"
wait
docker exec app_platform-backend-1 rm -f $PROBE
python3 - "$t_step" "$t_back" <<'EOF'
import sys
t_step, t_back = float(sys.argv[1]), float(sys.argv[2])
rows = [l.split() for l in open('/tmp/step.log') if l[0].isdigit()]
rows = [(float(t), int(c), float(m)) for t, c, m in rows]
base = [m for t, c, m in rows if t < t_step]
stepped = [m for t, c, m in rows if t_step + 1.5 < t < t_back]
if not base or not stepped:
    sys.exit(f"not enough images: {len(rows)}")
b, s = sum(base) / len(base), sum(stepped) / len(stepped)
thr = (b + s) / 2
dts = [b2[0] - a[0] for a, b2 in zip(rows, rows[1:])]
print(f"images {len(rows)}, interval mean {sum(dts)/len(dts)*1000:.0f} ms, brightness {b:.1f} -> {s:.1f}")
for label, t_ev, up in (("step", t_step, s > b), ("back", t_back, b > s)):
    hit = next((r for r in rows if r[0] > t_ev and ((r[2] > thr) if up else (r[2] < thr))), None)
    print(f"{label}: {'%.0f ms' % ((hit[0] - t_ev) * 1000) if hit else 'no change'}")
EOF
