"""Latency per stage from the metaData timestamps of the live images (socket.io
client on the Pi itself, same clock as camera app and backend).
Usage (in the backend container): python stage_probe.py [seconds]"""
import asyncio, json, statistics, sys, time
import socketio

STAGES = [  # name, from, to
    ("v4l2Queue", "tSensor", "tDequeue"),
    ("cameraApp", "tDequeue", "tCamSend"),
    ("zmq", "tCamSend", "tCam"),
    ("backend", "tCam", "tSent"),
    ("socket", "tSent", "tRecv"),
    ("total", "tSensor", "tRecv"),
]
rows = []
sio = socketio.AsyncClient()


@sio.on('image')
async def on_image(data):
    t = time.time()
    meta = json.loads(data).get("metaData") or {}
    meta["tRecv"] = t
    rows.append(meta)


async def main():
    await sio.connect("http://localhost:8000", socketio_path="/ws/socket.io/", transports=["websocket"], wait_timeout=15)
    await sio.emit("activeCamera", 0)
    await asyncio.sleep(float(sys.argv[1]) if len(sys.argv) > 1 else 20)
    await sio.disconnect()

asyncio.run(main())

print(f"images {len(rows)}")
for name, a, b in STAGES:
    v = sorted((r[b] - r[a]) * 1000 for r in rows if r.get(a) and r.get(b))
    if not v:
        print(f"{name:10s} no data")
        continue
    print(f"{name:10s} mean {statistics.mean(v):6.0f}  p50 {v[len(v) // 2]:6.0f}  "
          f"p95 {v[min(len(v) - 1, int(len(v) * .95))]:6.0f}  max {v[-1]:6.0f} ms")
