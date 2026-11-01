"""Latency per stage from the metaData timestamps of the live images (socket.io
client on the Pi itself, same clock as camera app and backend).
Usage (in the backend container): python stage_probe.py [seconds] [--new-client WIDTH]
--new-client: behaves like the current frontend - announces binary images and
image acks, reports WIDTH as display width and confirms every image."""
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
args = sys.argv[1:]
new_client = "--new-client" in args
width = int(args[args.index("--new-client") + 1]) if new_client else 0
seconds = float(args[0]) if args and not args[0].startswith("--") else 20
rows, sizes = [], []
sio = socketio.AsyncClient()


@sio.on('image')
async def on_image(data):
    t = time.time()
    msg = json.loads(data) if isinstance(data, str) else data
    sizes.append(len(data) if isinstance(data, str) else len(msg.get("image") or b""))
    meta = msg.get("metaData") or {}
    meta["tRecv"] = t
    rows.append(meta)
    if new_client:
        await sio.emit("imageAck", {"counter": msg.get("counter")})


async def main():
    await sio.connect("http://localhost:8000", socketio_path="/ws/socket.io/", transports=["websocket"], wait_timeout=15)
    if new_client:
        await sio.emit("clientCapabilities", {"binaryImages": True, "imageAck": True})
        await sio.emit("previewSize", {"width": width})
    await sio.emit("activeCamera", 0)
    await asyncio.sleep(seconds)
    await sio.disconnect()

asyncio.run(main())

print(f"images {len(rows)}, image message size {sum(sizes) // max(1, len(sizes)) // 1000} KB"
      + (f" (binary, display width {width})" if new_client else " (legacy JSON)"))
for name, a, b in STAGES:
    v = sorted((r[b] - r[a]) * 1000 for r in rows if r.get(a) and r.get(b))
    if not v:
        print(f"{name:10s} no data")
        continue
    print(f"{name:10s} mean {statistics.mean(v):6.0f}  p50 {v[len(v) // 2]:6.0f}  "
          f"p95 {v[min(len(v) - 1, int(len(v) * .95))]:6.0f}  max {v[-1]:6.0f} ms")
