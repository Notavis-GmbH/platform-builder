import uvicorn
from fastapi import FastAPI, Response
from starlette.types import Scope
from starlette.exceptions import HTTPException
from contextlib import asynccontextmanager
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from routers.SocketServer import sio, cameraStreams, callback
import socketio
import os
import asyncio
import logging
import sys
import json
import importlib
from datetime import datetime
import cv2
from operator import itemgetter
import base64
import threading
import numpy as np
import time
import dotenv
# append the path of the
# parent directory
sys.path.append("..")

if os.path.exists(".env"):
    dotenv.load_dotenv(".env")
    
from Helpers.ImageHelper import ImageHelper
from routers import ftpRouter, ImagerSettings, imageHistory, intervalRouter, imageRouter, genicamRouter, frontendRouter, appRouter, licenseRouter, imagerSelectionV2, authRouter
from routers.appRouter import apps, processImage,processImageRawMessage, connectApps, apps_initialized
from Helpers.ConnectionClass import CameraConnection
from Helpers.IPCHelper import cleanup_ipc_paths
from routers.imageHistory import  store_image_automatically, store_last_image
from uvicorn.config import LOGGING_CONFIG
import os
from RedisHelper.Redisclient import RedisClient

# Create a global instance of RedisClient with proper configuration
redis_client = RedisClient()
redis_client.host = os.getenv("REDIS_HOST", "localhost")
redis_client.port = int(os.getenv("REDIS_PORT", 6379))
redis_client.db = 0
redis_client.channel = os.getenv("CONTROL_CHANNEL", "camera_control")

ZMQ_USE_MSGPACK = os.getenv("ZMQ_USE_MSGPACK", "false").lower() in ("1", "true", "yes", "on")

# Repeated ZMQ error messages (e.g. image storage failures) can arrive at frame rate.
# Only forward the same error to the frontend once per this interval so the
# mat-snackbar doesn't get re-triggered dozens of times a second.
ERROR_EMIT_MIN_INTERVAL_S = 5

logger = logging.getLogger("app")

logger.setLevel(logging.INFO)

logger.info(imageRouter.env_variables)

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    logging.info("startup_event")
    cleanup_ipc_paths()
    
    # Redis health check
    try:
        redis_client.callback = handle_redis_message
        await redis_client.connect(max_retries=10, retry_delay=5)
        logger.info("Redis connected successfully")
    except Exception as e:
        logger.error(f"Redis connection failed: {e}")
        raise
    
    if(imageRouter.env_variables.app_active):
        await connectApps()
    start_zmq_loop()
    yield
    # Shutdown
    logging.info("shutdown_event")
    for cameraConnection in imageRouter.cameraConnections:
        if(cameraConnection.image_source != None):
            cameraConnection.image_source.cancelToken = True

app = FastAPI(lifespan=lifespan)


countercreate_zmq_loop= 0
activeCameras = []
current_counter_client = 0
skipped_image_counter = 0
# Framerate measurement - rolling average over last 5 frames
frame_timestamps = {}  # Stores list of last 5 timestamps per camera
# app.mount("/api", ASGIApp(socketio_server=sio))
def start_zmq_loop():
    asyncio.get_event_loop().create_task(create_zmq_loop())

appASGI = socketio.ASGIApp(sio, app, socketio_path="/ws/socket.io/")

app.include_router(authRouter.router)
app.include_router(ftpRouter.router)
app.include_router(ImagerSettings.router)
app.include_router(imageHistory.router)
app.include_router(imageRouter.router)
app.include_router(intervalRouter.router)
app.include_router(genicamRouter.router)
app.include_router(appRouter.router)
app.include_router(frontendRouter.router)
app.include_router(licenseRouter.router)
app.include_router(imagerSelectionV2.router)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*", "http://localhost:80","http://localhost:8080", "http://raspi4:80", "http://raspi4:8080", "http://raspi4-nano-c:8080", "http://raspi4-nano-c:80"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)



@sio.on('activeCamera')
async def on_active_camera(sid, data):
    global cameraStreams
    cameraStreams.updateActiveCamera(sid, data)
    logging.info(f"Active camera: {data}")
    if not imageRouter.is_live_streaming_enabled(data):
        return
    cameraConnection = imageRouter.get_camera_connection(data)
    if(cameraConnection.encodeImageStored):
        await stream_image_encoded(cameraConnection)
    else:
        await stream_image_raw(cameraConnection)

# as a decorator:


@sio.on('currentCounter', namespace='/')
def current_counter(sid, data):
    global current_counter_client
    current_counter_client = data
    return True
imageHelper = ImageHelper()


async def stream_image_raw(cameraConnection: CameraConnection): 

        
    lastImage = cameraConnection.lastImage
    if(lastImage is None):
        logger.warning("No raw image to stream")
        return
    if(lastImage.shape[0]* lastImage.shape[1] > 1_000_000):
        scaleFactor = lastImage.shape[0]* lastImage.shape[1] / 1_000_000
        logger.debug(f"Scale image by {scaleFactor}")
        lastImage = cv2.resize(lastImage, None, fx=1/scaleFactor, fy=1/scaleFactor)
    try:
        strImage = imageHelper.decodeImage(lastImage)

        logger.info(cameraConnection.lastImage.shape)
    except Exception as e:
        logger.error(f"Error encoding image: {e}")
        return

    # Latenzmessung: Zeitpunkt der Uebergabe an socket.io
    cameraConnection.metaData["tSent"] = time.time()
    await sio.emit('image', json.dumps({"image": strImage,
                                        "size": cameraConnection.lastImage.shape,
                                        "counter": cameraConnection.counter,
                                        "cameraId": cameraConnection.id,
                                        "results": cameraConnection.results,
                                        "metaData": cameraConnection.metaData})

                )
async def stream_image_encoded(cameraConnection: CameraConnection): 
    global logger
    
    tStart = time.time()
    if(cameraConnection.base64Image == None and cameraConnection.lastImageEncoded != None):   
        cameraConnection.base64Image = base64.b64encode(cameraConnection.lastImageEncoded).decode()       
    tAfterB64 = time.time()

    logger.debug(cameraConnection.imageShape)

    # Latenzmessung: Zeitpunkt der Uebergabe an socket.io
    cameraConnection.metaData["tSent"] = time.time()
    payload = json.dumps({"image": cameraConnection.base64Image,
                                        "size": cameraConnection.imageShape,
                                        "counter": cameraConnection.counter,
                                        "cameraId": cameraConnection.id,
                                         "results": cameraConnection.results,
                                         "metaData": cameraConnection.metaData})
    tAfterDumps = time.time()

    await sio.emit('image', payload)
    tAfterEmit = time.time()

    b64len = len(cameraConnection.base64Image) if cameraConnection.base64Image else 0
    logger.info(
        f"[stream_image_encoded] b64len={b64len} "
        f"b64encode={tAfterB64 - tStart:.3f}s json.dumps={tAfterDumps - tAfterB64:.3f}s "
        f"sio.emit={tAfterEmit - tAfterDumps:.3f}s total={tAfterEmit - tStart:.3f}s"
    )


# --- Entkopplung App-Aufruf / Kamera-Callback -------------------------------
# Der Kamera-Callback (callback_image_received) muss so schnell wie moeglich
# zurueckkehren, damit die zmqloop() in IPCHelper.py das naechste Kamerabild
# empfangen kann (der Empfang ist ein striktes "await recv -> await callback").
# Der App-Aufruf (processImage) blockierte bisher genau diesen Callback.
#
# Loesung: Einzelplatz-Puffer pro Kamera-ID (Overwrite-Semantik statt Queue).
# Ein Hintergrund-Task verarbeitet immer nur das zuletzt eingetroffene Bild.
# Ist die App langsamer als die Kamera, werden dazwischenliegende Frames fuer
# die App automatisch uebersprungen (Frame-Skipping) - die Kamera selbst
# liefert dennoch jeden Frame mit voller Rate an den Client.
_app_latest_frame: dict = {}      # id -> letztes Rohbild, wartet auf App-Verarbeitung
_app_worker_started: dict = {}    # id -> Worker-Task bereits gestartet?
_app_latest_frame_time: dict = {} # id -> Zeitstempel des Bildes in _app_latest_frame (Latenzmessung)


def _start_app_worker_if_needed(id: int):
    global logger
    if not _app_worker_started.get(id, False):
        _app_worker_started[id] = True
        asyncio.create_task(_app_worker_loop(id))
        logger.info(f"App-Worker-Task fuer Kamera {id} gestartet (entkoppelt vom Kamera-Callback)")


async def _app_worker_loop(id: int):
    """Verarbeitet Kamerabilder durch die externe App, unabhaengig vom
    Kamera-Callback. Nimmt pro Durchlauf das zuletzt hinterlegte Bild aus
    _app_latest_frame; waehrend eine Verarbeitung laeuft, sammeln sich keine
    weiteren Auftraege an (Einzelplatz statt Queue) - es wird also nie mehr
    als ein App-Aufruf gleichzeitig fuer dieselbe Kamera-ID ausgeloest.

    Ist alleinige Sendestelle an das Frontend, SOLANGE die App aktiv ist
    (siehe callback_image_received - der Callback sendet in diesem Fall
    bewusst nichts). Dadurch blockiert auch das teure Encodieren/Senden des
    grossen annotierten Bildes (~100-150ms) nie den Kamera-Callback; das
    Overlay bleibt sichtbar, bis dieser Task das naechste Ergebnis liefert."""
    global logger
    while True:
        await asyncio.sleep(0.001)
        frame = _app_latest_frame.get(id)
        if frame is None:
            continue
        _app_latest_frame[id] = None
        frameTimes = _app_latest_frame_time.get(id, {})

        try:
            cameraConnection = imageRouter.get_camera_connection(id)
            cameraConnection.lastRawImage = frame
            for app in apps:
                if (app.active and app.connected):
                    tStart = time.time()
                    results = await processImage(apps[0], frame)
                    tAfterProcess = time.time()
                    processedImage = cameraConnection.image_source.castImageMultiMessage(results)
                    tAfterCast = time.time()
                    logger.info(
                        f"[AppWorker {id}] Gesamt {tAfterCast - tStart:.3f}s "
                        f"(processImage {tAfterProcess - tStart:.3f}s, "
                        f"castImageMultiMessage {tAfterCast - tAfterProcess:.3f}s), "
                        f"Bildform {processedImage.shape if processedImage is not None else None}"
                    )

                    cameraConnection.results = results[0]
                    cameraConnection.lastImage = processedImage
                    cameraConnection.lastImageEncoded = None
                    cameraConnection.encodeImageStored = False
                    # Regression-Fix: imageShape wurde hier vergessen (im alten
                    # Callback-Pfad immer per itemgetter aus message["dataformat"]
                    # gesetzt). Ohne das bekommt das Frontend size=None mitgeschickt
                    # und kann das Bild nicht rendern - dadurch blieb der Stream leer.
                    if processedImage is not None:
                        cameraConnection.imageShape = processedImage.shape

                    canStream = (imageRouter.is_live_streaming_enabled(id)
                                 and cameraStreams.countOpenConnections() > 0
                                 and cameraStreams.checkCameraIsActive(id))

                    tBeforeSend = time.time()
                    # Kein await bis zum json.dumps in stream_image_*: der
                    # Kamera-Callback kann die Werte vorher nicht ueberschreiben.
                    cameraConnection.metaData.update(frameTimes)
                    if isinstance(results[0], dict) and "base64" in results[0] and results[0]["base64"] is not None:
                        cameraConnection.base64Image = results[0]["base64"]
                        cameraConnection.jpgResized = True
                        if canStream:
                            await stream_image_encoded(cameraConnection)
                    else:
                        cameraConnection.base64Image = None
                        if canStream:
                            await stream_image_raw(cameraConnection)
                    logger.info(f"[AppWorker {id}] Encode+Send {time.time() - tBeforeSend:.3f}s")
                    break
        except Exception as e:
            logger.error(f"[AppWorker {id}] Fehler bei App-Verarbeitung: {e}")
# -----------------------------------------------------------------------------


async def callback_image_received(message: dict, id: int):
    global logger, cameraStreams, current_counter_client, skipped_image_counter, frame_timestamps, apps_initialized
    fps = 0.0
    # Framerate measurement - rolling average over last 5 frames
    current_time = time.time()
    if id not in frame_timestamps:
        frame_timestamps[id] = []
    
    frame_timestamps[id].append(current_time)
    
    # Keep only last 5 timestamps
    if len(frame_timestamps[id]) > 5:
        frame_timestamps[id].pop(0)
    
    # Calculate FPS when we have at least 2 frames
    if len(frame_timestamps[id]) >= 2:
        time_span = frame_timestamps[id][-1] - frame_timestamps[id][0]
        num_intervals = len(frame_timestamps[id]) - 1
        if time_span > 0:
            fps = num_intervals / time_span
            logger.info(f"Camera {id} FPS (avg over {len(frame_timestamps[id])} frames): {fps:.2f}")

    logger.debug(f"Camera {id} openConnections: {cameraStreams.countOpenConnections()}")
    """Callback function for image received event"""
    cameraConnection = imageRouter.get_camera_connection(id)
    cameraConnection.metaData["fps"] = fps
    # Latenzmessung: Empfangszeit im Backend und Zeitstempel der Kamera-App
    # (Unix-Sekunden): V4L2-Puffer, Dequeue, ZMQ-Versand
    cameraConnection.metaData["tCam"] = current_time
    for key in ("tSensor", "tDequeue", "tCamSend"):
        cameraConnection.metaData[key] = message.get(key)
    strImage = ""
    if(current_counter_client != 0 and current_counter_client + 40 < cameraConnection.counter and skipped_image_counter < 2  ):
        logger.info(f"Skip image {current_counter_client} {cameraConnection.counter} {skipped_image_counter}")
        skipped_image_counter += 1
        return
    else:
        skipped_image_counter = 0
    cameraConnection.counter += 1
    imageRouter.lastImageTimestamp = datetime.now()
    logger.info(message["dataformat"]["type"])
    if(message["dataformat"]["type"]== "jpg"):
        cameraConnection.lastImageEncoded = message["data"]
        cameraConnection.imageShape = itemgetter('rows', 'cols', 'channels')(message["dataformat"])
        input = np.frombuffer(bytes(cameraConnection.lastImageEncoded), np.uint8)                           

        lastImage = cv2.imdecode(input, cv2.IMREAD_COLOR)
        if lastImage is not None:
            cameraConnection.lastRawImage = lastImage.copy()
        for app in apps:
            if (app.active and app.connected):
                lastImage, results = await processImage(apps[0], lastImage)
                logger.info(lastImage.shape)
                cameraConnection.results = results
                break
        if lastImage is None:
            return

        cameraConnection.encodeImageStored = True
        cameraConnection.base64Image = None
        if lastImage is  not None:
            cameraConnection.lastImage = lastImage

            if imageRouter.is_live_streaming_enabled(id):
                await stream_image_raw(cameraConnection)
        elif(imageRouter.is_live_streaming_enabled(id) and cameraStreams.countOpenConnections() > 0 and cameraStreams.checkCameraIsActive(id) ):
            await stream_image_encoded(cameraConnection)
    elif(message["dataformat"]["type"]== "base64jpg"):
        cameraConnection.lastImageEncoded = None
        cameraConnection.base64Image = message["base64"]
        cameraConnection.imageShape = itemgetter('rows', 'cols', 'channels')(message["dataformat"])
        cameraConnection.encodeImageStored = True
        cameraConnection.jpgResized = message["jpgResized"]
        
        
        for app in apps:
            # logger.info(f"App {app.active} {app.connected}")
            if (app.active and app.connected):
                input = base64.b64decode(cameraConnection.base64Image)
                input = np.frombuffer(bytes(input), np.uint8)                          

                lastImage = cv2.imdecode(input, cv2.IMREAD_COLOR)
                if lastImage is not None:
                    cameraConnection.lastRawImage = lastImage.copy()
                lastImage, results = await processImage(apps[0], lastImage)
                if lastImage is  not None:
                    cameraConnection.lastImage = lastImage
                    cameraConnection.results = results

                #     await stream_image_raw(cameraConnection)
                # return

        if(imageRouter.is_live_streaming_enabled(id) and cameraStreams.countOpenConnections() > 0 and cameraStreams.checkCameraIsActive(id)):
            await stream_image_encoded(cameraConnection)
    elif(message["dataformat"]["type"]== "both"):
        start = time.time()
        
        lastImage = cameraConnection.image_source.castImage(message)
        logger.info(f"Cast image for both {time.time() - start}")
        start = time.time()

        # Entkoppelt (siehe _app_worker_loop oben): der Kamera-Callback wartet
        # nicht mehr auf processImage(). Das Rohbild wird sofort an den
        # Hintergrund-Worker weitergereicht (immer nur das zuletzt eingetroffene
        # Bild - Frame-Skipping statt Blockade). Solange die App aktiv ist,
        # sendet der Callback selbst NICHTS - der Worker ist dann alleinige
        # Sendestelle (siehe _app_worker_loop), damit auch das Encodieren/
        # Senden des grossen annotierten Bildes den Kamera-Callback nie
        # blockiert. Das Overlay bleibt sichtbar, bis der Worker das naechste
        # Ergebnis liefert; es gibt so nie zwei unabhaengige Sendequellen
        # gleichzeitig (kein Doppel-Emit/Flackern).
        app_should_run = imageRouter.env_variables.app_active and not apps_initialized

        if app_should_run:
            _start_app_worker_if_needed(id)
            # Kopie uebergeben: die naechste Kamera-Nachricht ueberschreibt
            # lastImage sonst, bevor der Worker es liest.
            tCopyStart = time.time()
            cameraConnection.lastRawImage = lastImage.copy()
            _app_latest_frame[id] = lastImage.copy()
            _app_latest_frame_time[id] = {key: cameraConnection.metaData.get(key) for key in ("tCam", "tSensor", "tDequeue", "tCamSend")}
            tCopyDur = time.time() - tCopyStart
            if tCopyDur > 0.005:
                logger.info(f"[Callback] lastImage.copy() dauerte {tCopyDur:.3f}s (Bildform {lastImage.shape})")
        else:
            cameraConnection.results = []
            cameraConnection.lastImage = lastImage
            cameraConnection.lastRawImage = lastImage
            cameraConnection.lastImageEncoded = None
            cameraConnection.base64Image = message["base64"]
            cameraConnection.imageShape = itemgetter('rows', 'cols', 'channels')(message["dataformat"])
            cameraConnection.encodeImageStored = True
            cameraConnection.jpgResized = "jpgResized" in message and message["jpgResized"]

            start = time.time()
            if(imageRouter.is_live_streaming_enabled(id) and cameraStreams.countOpenConnections() > 0 and cameraStreams.checkCameraIsActive(id)):
                await stream_image_encoded(cameraConnection)
            logger.info(f"Sending image {time.time() - start}")
            start = time.time()

    else: #raw
        lastImage = cameraConnection.image_source.castImage(message)
        if lastImage is not None:
            cameraConnection.lastRawImage = lastImage.copy()
        for app in apps:
            if (app.active and app.connected):
                lastImage = await processImage(apps[0], lastImage)
                break
        if lastImage is None:
            return
        cameraConnection.lastImage = lastImage
        cameraConnection.encodeImageStored = False
        if(imageRouter.is_live_streaming_enabled(id) and cameraStreams.countOpenConnections() > 0 and cameraStreams.checkCameraIsActive(id) ):
            await stream_image_raw(cameraConnection)
    if(await store_image_automatically(id)):
        await  sio.emit("historyUpdate", id)

async def infos_event(message: dict, id: int):
    global logger, sio
    logger.info(f"Camera {id}")
    cameraConnection = imageRouter.get_camera_connection(id)
    
    message.update({"cameraId": id})

    cameraConnection.infos = imageRouter.filterSettings(message)
    logger.info(message)
    await sio.emit("status", message)

    cameraConnection.image_source.event.set()
    

async def status_event(message: dict, id: int): 
    logging.info(f"Camera {id}")
    message.update({"cameraId": id})
    cameraConnection = imageRouter.get_camera_connection(id)
    cameraConnection.lastStatus = message
    logging.info(message)   
    await sio.emit("status", message)

async def error_event(message: dict, id: int):
    global logger
    error_text = message["error"]
    cameraConnection = imageRouter.get_camera_connection(id)
    now = time.monotonic()
    same_error = error_text == cameraConnection.lastError
    if same_error and (now - cameraConnection.lastErrorTime) < ERROR_EMIT_MIN_INTERVAL_S:
        return
    cameraConnection.lastError = error_text
    cameraConnection.lastErrorTime = now

    logger.info(f"Camera {id}")
    logger.info(message)
    await sio.emit("error", error_text)


async def handle_redis_message(message: dict):
    """
    Callback function for handling Redis messages from FTDI service.
    Processes start/stop commands and publishes status back to STATUS_CHANNEL.
    """
    global logger, redis_client
    try:
        logger.info(f"handle_redis_message called with: {message}")
        if isinstance(message, dict) and 'data' in message:
            data = message['data']
            # Handle both string and bytes data
            if isinstance(data, bytes):
                data_str = data.decode('utf-8')
            else:
                data_str = str(data)
            
            logger.info(f"data_str type: {type(data_str)}, value: {data_str}")
            try:
                command_data = json.loads(data_str)
                command = command_data.get('command', '')
                camera_id = command_data.get('camera_id', 0)
                
                logger.info(f"Received Redis command: {command} for camera {camera_id}")
                
                if command in ('start_camera', 'start'):
                    # Start the camera
                    try:
                        cameraConnection = imageRouter.get_camera_connection(camera_id)
                        camera_control = cameraConnection.camera_control
                        if camera_control is not None:
                            await camera_control.sendV4Command('start', None, False)
                            logger.info(f"Camera {camera_id} started")
                            # Publish status back to FTDI
                            await redis_client.publish_status(camera_id, "started")
                        else:
                            logger.error(f"Camera control not available for camera {camera_id}")
                    except Exception as e:
                        logger.error(f"Failed to start camera {camera_id}: {e}")
                        
                elif command in ('stop_camera', 'stop'):
                    # Stop the camera
                    try:
                        cameraConnection = imageRouter.get_camera_connection(camera_id)
                        camera_control = cameraConnection.camera_control
                        if camera_control is not None:
                            await camera_control.sendV4Command('stop', None, False)
                            logger.info(f"Camera {camera_id} stopped")
                            # Publish status back to FTDI
                            await redis_client.publish_status(camera_id, "stopped")
                        else:
                            logger.error(f"Camera control not available for camera {camera_id}")
                    except Exception as e:
                        logger.error(f"Failed to stop camera {camera_id}: {e}")
                        
                elif command == 'TOGGLE':
                    # Toggle camera state
                    try:
                        cameraConnection = imageRouter.get_camera_connection(camera_id)
                        # Check current status from infos
                        is_running = False
                        if cameraConnection.infos:
                            is_running = cameraConnection.infos.get('running', False)
                        
                        if is_running:
                            # Stop if running
                            camera_control = cameraConnection.camera_control
                            if camera_control is not None:
                                await camera_control.sendV4Command('stop', None, False)
                                logger.info(f"Camera {camera_id} toggled off")
                                await redis_client.publish_status(camera_id, "stopped")
                        else:
                            # Start if stopped
                            camera_control = cameraConnection.camera_control
                            if camera_control is not None:
                                await camera_control.sendV4Command('start', None, False)
                                logger.info(f"Camera {camera_id} toggled on")
                                await redis_client.publish_status(camera_id, "started")
                    except Exception as e:
                        logger.error(f"Failed to toggle camera {camera_id}: {e}")
                elif command == 'get_status':
                    try:
                        cameraConnection = imageRouter.get_camera_connection(camera_id)
                        # Wait up to 2s for ZMQ infos to arrive if not yet populated
                        for _ in range(20):
                            if cameraConnection.infos is not None:
                                break
                            await asyncio.sleep(0.1)
                        is_running = cameraConnection.infos.get('running', False) if cameraConnection.infos else False
                        status = "started" if is_running else "stopped"
                        await redis_client.publish_status(camera_id, status)
                        logger.info(f"Camera {camera_id} status reported: {status} (infos available: {cameraConnection.infos is not None})")
                    except Exception as e:
                        logger.error(f"Failed to get status for camera {camera_id}: {e}")
                else:
                    logger.warning(f"Unknown command: {command}")
            except json.JSONDecodeError as e:
                logger.error(f"Failed to parse Redis message: {e}")
        else:
            logger.debug(f"Received invalid message format: {message}")
    except Exception as e:
        logger.error(f"Error handling Redis message: {e}")



async def start_zmq_loop_cam(connection: int):
    global logger
    logger.info(f"Start {connection} camera")

    await imageRouter.get_camera_connection(connection).image_source.zmqloop({"data": callback_image_received,
                                    "infos": infos_event,
                                    "error": error_event,
                                    "status": status_event}, 
                                    isMsgpack=ZMQ_USE_MSGPACK
                               )
async def create_zmq_loop():
    global logger, countercreate_zmq_loop
    countercreate_zmq_loop += 1

    for i in range(imageRouter.backendRuntimeSettings.count_camera_connections-1):
        logger.info(f"create_zmq_loop {countercreate_zmq_loop}")

        threading.Thread(target=asyncio.run, args=(start_zmq_loop_cam(i),)).start()    
    
    await start_zmq_loop_cam(imageRouter.backendRuntimeSettings.count_camera_connections-1)

@app.get("/simulate")
async def simulate():
    global cameraStreams,logger
    image = cv2.imread("./data-matrix-qr-codes-1_0.jpg", cv2.IMREAD_GRAYSCALE)
    logger.info(image.shape)
    message = {"data": cv2.imencode(".jpg",image)[1], "dataformat": {"type": "jpg", "rows": image.shape[0], "cols": image.shape[1], "channels": 1}}
    await callback_image_received(message, 0)
    return "Simulate"    
        
class SPAStaticFiles(StaticFiles):
    async def get_response(self, path: str, scope: Scope) -> Response:
        logger.info("New response")
        try:
            response = await super().get_response(path, scope)
            return response
        except HTTPException as excp:
            logging.info(f"Not in scope {path}")
            response = await super().get_response('.', scope)
            return response


     

importlib.import_module("routers.SocketIO")
app.mount("/", SPAStaticFiles(directory=os.path.join(os.path.dirname(os.path.abspath(__file__)), "static"), html=True), name="static")


async def sendlastStatus():
     for cameraConnection in imageRouter.cameraConnections:
        logger.info(f"Camera {cameraConnection.id} infos: {cameraConnection.infos}")
        if(cameraConnection.lastStatus != None):
            await sio.emit("status", cameraConnection.lastStatus )

callback = sendlastStatus


def callback_trigger(message:dict):
    global logger
    logger.info(message)
    asyncio.run(imageHistory.store_last_image(0, False))
    
if __name__ == "__main__":
    try:
        
        # LOGGING_CONFIG["formatters"]["access"]["fmt"] = '%(asctime)s %(levelprefix)s %(client_addr)s - "%(request_line)s" %(status_code)s'
        # LOGGING_CONFIG["formatters"]["default"]["fmt"] = "%(asctime)s %(levelprefix)s %(message)s"

        # date_fmt = "%Y-%m-%d %H:%M:%S"
        # LOGGING_CONFIG["formatters"]["default"]["datefmt"] = date_fmt
        # LOGGING_CONFIG["formatters"]["access"]["datefmt"] = date_fmt

        
        # logger.info(json.dumps(LOGGING_CONFIG, indent=4))
        # redisclient = Redisclient.RedisClient(imageRouter.env_variables.redis_host, imageRouter.env_variables.redis_port, imageRouter.env_variables.redis_db, imageRouter.env_variables.redis_channel, callback_trigger)

        uvicorn.run(appASGI, host="*", port=8000, log_config="./logging.json")
    except asyncio.exceptions.CancelledError as excp:
        logging.error(excp)
    
