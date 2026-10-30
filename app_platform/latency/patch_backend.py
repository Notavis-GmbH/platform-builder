"""Adds the latency timestamps to appBackend.py of the backend image (2.5.0/2.6.0):
tCam (frame received from the camera), tSent (handed to socket.io) and the
camera app's tSensor/tDequeue/tCamSend, all in metaData of every 'image' event.
Usage: patch_backend.py <appBackend.py in> <appBackend.py out>"""
import sys

src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()

TIMES = '("tCam", "tSensor", "tDequeue", "tCamSend")'
edits = [
    # stream_image_raw
    ("    await sio.emit('image', json.dumps({\"image\": strImage,\n",
     "    # Latenzmessung: Zeitpunkt der Uebergabe an socket.io\n"
     "    cameraConnection.metaData[\"tSent\"] = time.time()\n"
     "    await sio.emit('image', json.dumps({\"image\": strImage,\n"),
    # stream_image_encoded
    ("    payload = json.dumps({\"image\": cameraConnection.base64Image,\n",
     "    # Latenzmessung: Zeitpunkt der Uebergabe an socket.io\n"
     "    cameraConnection.metaData[\"tSent\"] = time.time()\n"
     "    payload = json.dumps({\"image\": cameraConnection.base64Image,\n"),
    ("_app_worker_started: dict = {}    # id -> Worker-Task bereits gestartet?\n",
     "_app_worker_started: dict = {}    # id -> Worker-Task bereits gestartet?\n"
     "_app_latest_frame_time: dict = {} # id -> Zeitstempel des Bildes in _app_latest_frame (Latenzmessung)\n"),
    ("        _app_latest_frame[id] = None\n",
     "        _app_latest_frame[id] = None\n"
     "        frameTimes = _app_latest_frame_time.get(id, {})\n"),
    ("                    tBeforeSend = time.time()\n",
     "                    tBeforeSend = time.time()\n"
     "                    # Kein await bis zum json.dumps in stream_image_*: der\n"
     "                    # Kamera-Callback kann die Werte vorher nicht ueberschreiben.\n"
     "                    cameraConnection.metaData.update(frameTimes)\n"),
    ("    cameraConnection.metaData[\"fps\"] = fps\n",
     "    cameraConnection.metaData[\"fps\"] = fps\n"
     "    # Latenzmessung: Empfangszeit im Backend und Zeitstempel der Kamera-App\n"
     "    # (Unix-Sekunden): V4L2-Puffer, Dequeue, ZMQ-Versand\n"
     "    cameraConnection.metaData[\"tCam\"] = current_time\n"
     "    for key in (\"tSensor\", \"tDequeue\", \"tCamSend\"):\n"
     "        cameraConnection.metaData[key] = message.get(key)\n"),
    ("            _app_latest_frame[id] = lastImage.copy()\n",
     "            _app_latest_frame[id] = lastImage.copy()\n"
     f"            _app_latest_frame_time[id] = {{key: cameraConnection.metaData.get(key) for key in {TIMES}}}\n"),
]
for old, new in edits:
    n = s.count(old)
    if n != 1:
        sys.exit(f"anchor found {n}x: {old.strip()[:70]}")
    s = s.replace(old, new)
open(dst, "w").write(s)
print(f"patched {dst}")
