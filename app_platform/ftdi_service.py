import redis
import time
import json
import logging
import os
import sys

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Configuration from environment variables
REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", 6379))
CONTROL_CHANNEL = os.getenv("CONTROL_CHANNEL", "camera_control")
STATUS_CHANNEL = os.getenv("STATUS_CHANNEL", "camera_status")
FTDI_CHANNEL = os.getenv("FTDI_CHANNEL", "ftdi_control")  # Redis channel for remote toggle input
FTDI_STATE_KEY = os.getenv("FTDI_STATE_KEY", "ftdi:state")  # Redis key: current state machine state
FTDI_RTS_KEY = os.getenv("FTDI_RTS_KEY", "ftdi:rts")        # Redis key: current RTS output (HIGH/LOW)

# Hardware Configuration
SERIAL_PORT = os.getenv("SERIAL_PORT", "/dev/ttyUSB0")
SIMULATION_MODE = os.getenv("SIMULATION_MODE", "True").lower() == "true"

STARTUP_DELAY = float(os.getenv("STARTUP_DELAY", 10.0))  # Seconds to wait at boot for networking/hardware to settle
WAITING_START_DELAY = float(os.getenv("WAITING_START_DELAY", 5.0))  # Seconds to wait after button press before sending start command

def connect_to_redis_with_retry(max_retries=10, retry_delay=5):
    """Connect to Redis with retry logic for slow-starting services"""
    for attempt in range(1, max_retries + 1):
        try:
            r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)
            r.ping()
            logger.info(f"Successfully connected to Redis on attempt {attempt}")
            return r
        except Exception as e:
            if attempt < max_retries:
                logger.warning(f"Redis connection attempt {attempt}/{max_retries} failed: {e}. Retrying in {retry_delay}s...")
                time.sleep(retry_delay)
            else:
                raise e

def run_ftdi_service():
    logger.info(f"Waiting {STARTUP_DELAY}s for networking and hardware to settle...")
    time.sleep(STARTUP_DELAY)

    try:
        r = connect_to_redis_with_retry()
        pubsub = r.pubsub()
        pubsub.subscribe(STATUS_CHANNEL)
        pubsub.subscribe(FTDI_CHANNEL)

        logger.info(f"FTDI Service started. Mode: {'SIMULATION' if SIMULATION_MODE else 'HARDWARE'}")

        hardware_failed = False

        if not SIMULATION_MODE:
            import serial as serial_module
            ser = None
            try:
                ser = serial_module.Serial(SERIAL_PORT, baudrate=9600, timeout=1)
                logger.info(f"Connected to hardware on {SERIAL_PORT}")

                # Initialize RTS LOW — camera on/streaming is the safe default
                ser.rts = False
                last_cts_state = ser.cts

                # State machine states (RTS LOW = camera ON, RTS HIGH = camera OFF)
                STATE_UNKNOWN = "UNKNOWN"                    # Initial: querying actual camera state
                STATE_IDLE = "IDLE"                          # Camera off (RTS HIGH), waiting for button
                STATE_WAITING_START = "WAITING_START"        # RTS LOW, waiting delay before start command
                STATE_RUNNING = "RUNNING"                    # Camera running (RTS LOW)
                STATE_WAITING_STOP = "WAITING_STOP"          # Sent stop, waiting for backend confirmation
                STATE_WAITING_START_CONFIRMED = "WAITING_START_CONFIRMED"  # Sent start, waiting for backend confirmation

                WAITING_START_DELAY = float(os.getenv("WAITING_START_DELAY", "5.0"))

                current_state = STATE_UNKNOWN
                state_unknown_start = time.time()
                button_press_time = None
                pending_toggle = False  # Set by Redis FTDI_CHANNEL to simulate a button press

                r.publish(CONTROL_CHANNEL, json.dumps({"command": "get_status", "camera_id": 0}))
                logger.info("Queried initial camera status from backend")

                while not hardware_failed:
                    try:
                        # 1. Check for messages on STATUS_CHANNEL and FTDI_CHANNEL
                        message = pubsub.get_message(ignore_subscribe_messages=True)
                        if message:
                            channel = message.get('channel', '')

                            if channel == FTDI_CHANNEL:
                                try:
                                    cmd_data = json.loads(message['data'])
                                    if cmd_data.get('command') == 'toggle':
                                        logger.info("REDIS TOGGLE RECEIVED on FTDI_CHANNEL - simulating button press")
                                        pending_toggle = True
                                except (json.JSONDecodeError, KeyError) as e:
                                    logger.warning(f"Failed to parse FTDI channel message: {e}")

                            elif channel == STATUS_CHANNEL:
                              try:
                                status_data = json.loads(message['data'])
                                camera_status = status_data.get('status', '')
                                logger.info(f"STATUS RECEIVED: {status_data} (current state: {current_state})")

                                if current_state == STATE_UNKNOWN:
                                    if camera_status in ('started', 'start'):
                                        logger.info("Initial status: camera running - RTS LOW, entering RUNNING state")
                                        ser.rts = False
                                        current_state = STATE_RUNNING
                                    elif camera_status in ('stopped', 'stop'):
                                        # Camera is stopped but do NOT set RTS HIGH here —
                                        # only a button press should turn the camera off.
                                        # RTS stays LOW (safe state) and we wait for a button press to start.
                                        logger.info("Initial status: camera stopped - entering IDLE state (RTS stays LOW, use button to start)")
                                        current_state = STATE_IDLE

                                elif current_state == STATE_IDLE and camera_status in ('started', 'start'):
                                    # Camera started externally while we were idle — must not leave RTS HIGH during streaming
                                    logger.info("Camera started externally while IDLE - RTS LOW, entering RUNNING state")
                                    ser.rts = False
                                    current_state = STATE_RUNNING

                                elif current_state in (STATE_WAITING_START, STATE_WAITING_START_CONFIRMED) and camera_status in ('started', 'start'):
                                    logger.info("Camera start confirmed by backend - RTS already LOW, entering RUNNING state")
                                    ser.rts = False  # Ensure LOW (should already be)
                                    current_state = STATE_RUNNING
                                    button_press_time = None

                                elif current_state == STATE_WAITING_STOP and camera_status in ('stopped', 'stop'):
                                    logger.info("Camera stop confirmed by backend - setting RTS HIGH")
                                    ser.rts = True
                                    current_state = STATE_IDLE

                              except (json.JSONDecodeError, KeyError) as e:
                                logger.warning(f"Failed to parse status message: {e}")

                        # 2. Monitor CTS pin for rising edge, or Redis toggle
                        current_cts = ser.cts
                        button_triggered = (current_cts and not last_cts_state) or pending_toggle

                        if button_triggered:
                            if pending_toggle:
                                logger.info("REDIS TOGGLE - simulating button press")
                            else:
                                logger.info("CTS RISING EDGE DETECTED")
                            pending_toggle = False

                            if current_state == STATE_UNKNOWN:
                                logger.warning("Button press ignored - camera state not yet determined")

                            elif current_state == STATE_IDLE:
                                logger.info(f"Button pressed - powering camera ON (RTS LOW), waiting {WAITING_START_DELAY}s for camera to initialize...")
                                ser.rts = False  # Power camera ON
                                current_state = STATE_WAITING_START
                                button_press_time = time.time()

                            elif current_state == STATE_RUNNING:
                                logger.info("Button pressed - initiating stop sequence, waiting for backend confirmation...")
                                r.publish(CONTROL_CHANNEL, json.dumps({"command": "stop_camera", "camera_id": 0}))
                                current_state = STATE_WAITING_STOP
                                button_press_time = time.time()
                                # RTS stays LOW until backend confirms camera stopped

                        last_cts_state = current_cts

                        # Timeout fallback: if backend doesn't respond within 10s, assume camera is running
                        if current_state == STATE_UNKNOWN and time.time() - state_unknown_start > 10.0:
                            logger.warning("No status response from backend within 10s - defaulting to RUNNING state (RTS stays LOW)")
                            current_state = STATE_RUNNING

                        # Check if initialization delay has elapsed (for start sequence)
                        if current_state == STATE_WAITING_START and button_press_time:
                            if time.time() - button_press_time >= WAITING_START_DELAY:
                                logger.info(f"{WAITING_START_DELAY}s elapsed - sending start_camera signal")
                                r.publish(CONTROL_CHANNEL, json.dumps({"command": "start_camera", "camera_id": 0}))
                                current_state = STATE_WAITING_START_CONFIRMED
                                button_press_time = None

                        # Publish current state to Redis keys (TTL=10s so keys expire if service dies)
                        r.set(FTDI_STATE_KEY, current_state, ex=10)
                        r.set(FTDI_RTS_KEY, "HIGH" if ser.rts else "LOW", ex=10)

                        time.sleep(0.05)

                    except redis.RedisError as e:
                        # Redis error must not cause simulation fallback — keep serial/RTS intact and reconnect
                        logger.warning(f"Redis error in hardware loop: {e}. Setting RTS LOW and reconnecting...")
                        ser.rts = False  # Safe state: never leave RTS HIGH when uncertain
                        try:
                            r = connect_to_redis_with_retry()
                            pubsub = r.pubsub()
                            pubsub.subscribe(STATUS_CHANNEL)
                            pubsub.subscribe(FTDI_CHANNEL)
                            current_state = STATE_UNKNOWN
                            state_unknown_start = time.time()
                            r.publish(CONTROL_CHANNEL, json.dumps({"command": "get_status", "camera_id": 0}))
                            logger.info("Redis reconnected - re-queried camera status")
                        except Exception as reconnect_err:
                            logger.error(f"Redis reconnect failed: {reconnect_err}. Falling back to Simulation.")
                            hardware_failed = True

            except serial_module.SerialException as e:
                logger.error(f"Serial port error: {e}. Falling back to Simulation mode.")
                hardware_failed = True
            except Exception as e:
                logger.error(f"Unexpected hardware error: {e}. Falling back to Simulation mode.")
                hardware_failed = True
            finally:
                # Always ensure RTS is LOW on exit so streaming pipeline is not corrupted
                if ser is not None:
                    try:
                        ser.rts = False
                        logger.info("RTS set LOW on hardware exit (safe state)")
                    except Exception:
                        pass

        # Simulation mode
        if SIMULATION_MODE or hardware_failed:
            logger.info("Simulation Mode Active (Timer based)")
            last_press = time.time()
            while True:
                message = pubsub.get_message(ignore_subscribe_messages=True)
                if message:
                    logger.info(f"HANDSHAKE RECEIVED: {message['data']}")

                if time.time() - last_press > 15:
                    logger.info("SIMULATED BUTTON PRESS (Timer)")
                    r.publish(CONTROL_CHANNEL, json.dumps({"command": "TOGGLE", "camera_id": 0}))
                    last_press = time.time()
                time.sleep(0.1)

    except Exception as e:
        logger.error(f"Critical Error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    run_ftdi_service()
