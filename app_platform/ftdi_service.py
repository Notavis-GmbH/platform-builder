import redis
import time
import json
import logging
import os
import sys

import camera_sensor

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
CAMERA_HEALTH_KEY = os.getenv("CAMERA_HEALTH_KEY", "camera:health")  # Redis key: sensor readiness (JSON)

# Hardware Configuration
SERIAL_PORT = os.getenv("SERIAL_PORT", "/dev/ttyUSB0")
# "ftdi": power on RTS, button on CTS of the FTDI adapter
# "gpio": power and button on Raspberry Pi header GPIOs, see gpio_control.py (GPIO_* variables)
CONTROL_INTERFACE = os.getenv("CONTROL_INTERFACE", "ftdi").lower()
# Start the camera when the service starts (true), or switch the power off until
# the first start (false). Set in .env, see docker-compose.yml
START_CAMERA_AT_STARTUP = os.getenv("START_CAMERA_AT_STARTUP", "true").lower() == "true"
SIMULATION_MODE = os.getenv("SIMULATION_MODE", "True").lower() == "true"

# All durations use time.monotonic(): the Pi has no RTC, NTP moves the wall clock
# by minutes right after boot and would fire every running timeout at once.
STARTUP_DELAY = float(os.getenv("STARTUP_DELAY", 10.0))  # Seconds to wait at boot for networking/hardware to settle
SENSOR_READY_TIMEOUT = float(os.getenv("SENSOR_READY_TIMEOUT", 15.0))  # Seconds to wait after power on until the sensor answers on I2C
SENSOR_POLL_INTERVAL = float(os.getenv("SENSOR_POLL_INTERVAL", 0.2))   # Seconds between I2C readiness checks
BIND_RETRY_INTERVAL = float(os.getenv("BIND_RETRY_INTERVAL", 2.0))     # Seconds between driver bind attempts (each one is a full probe)
START_RETRY_INTERVAL = float(os.getenv("START_RETRY_INTERVAL", 5.0))   # Resend start_camera while the backend has not confirmed
START_CONFIRM_TIMEOUT = float(os.getenv("START_CONFIRM_TIMEOUT", 60.0))  # Give up waiting for the start confirmation
STOP_CONFIRM_TIMEOUT = float(os.getenv("STOP_CONFIRM_TIMEOUT", 30.0))  # Give up waiting for the stop confirmation (power stays on)
SENSOR_LOST_TIMEOUT = float(os.getenv("SENSOR_LOST_TIMEOUT", 3.0))     # Seconds a bound sensor may not answer (while powered) before it counts as lost
SENSOR_MONITOR_INTERVAL = float(os.getenv("SENSOR_MONITOR_INTERVAL", 1.0))  # Seconds between sensor checks while powered and not starting
LOST_STOP_TIMEOUT = float(os.getenv("LOST_STOP_TIMEOUT", 5.0))         # Max. seconds to wait for the stop confirmation of a lost sensor before waiting for it to return
SENSOR_SETTLE_TIME = float(os.getenv("SENSOR_SETTLE_TIME", 2.0))       # Start when one sensor is ready and the others did not answer within this time
# Camera I2C devices to watch, e.g. "0-001a" (comma separated). Empty: all camera devices of the device tree
CAMERA_I2C_DEVICES = [d.strip() for d in os.getenv("CAMERA_I2C_DEVICES", "").split(",") if d.strip()]


class SensorWatch:
    """Polls the camera sensor(s) over I2C until they answer and binds the
    driver if its probe failed (sensor not powered while booting), see
    camera_sensor.py. The result is published as JSON to CAMERA_HEALTH_KEY.

    The driver stays bound when the sensor is lost (cable, power), so a bound
    device that does not answer for SENSOR_LOST_TIMEOUT counts as "lost". It
    is NOT unbound: after unbind + bind, rp1-cfe registers its video devices
    a second time ("Rejecting subdev ... Already set!!", kobject warning) and
    the camera only works again after a reboot. A bound driver keeps working
    when the sensor is repowered (reset-always), so only devices that were
    never bound (probe at boot failed) are bound."""

    def __init__(self):
        self.health = {"state": "unknown", "message": "", "ts": time.time()}
        self.devices = {}
        self.results = []
        self.missing_since = {}  # dev -> time since the bound device does not answer
        self.last_poll = 0.0
        self.last_bind = 0.0

    def power_changed(self):
        """Sensor power switched: restart the grace time for lost sensors."""
        self.missing_since.clear()

    def lost(self):
        return [res for res in self.results if res["state"] == "lost"]

    def set_state(self, state, message, **extra):
        if state != self.health.get("state") or message != self.health.get("message"):
            log = logger.info if state in ("ready", "powered_off", "no_device") else logger.error if state == "lost" else logger.warning
            log(f"Sensor: {state} - {message}")
        self.health = {"state": state, "message": message, **extra, "ts": time.time()}

    def any_ready(self):
        return any(res["state"] == "ready" for res in self.results)

    def poll(self, bind=True):
        """True when all camera devices are ready (or none is known). Rate
        limited to SENSOR_POLL_INTERVAL, returns False in between.

        bind=True (camera not streaming): bind never bound devices whose
        sensor answers. bind=False (streaming): only detect."""
        now = time.monotonic()
        if now - self.last_poll < SENSOR_POLL_INTERVAL:
            return False
        self.last_poll = now

        try:
            devices = camera_sensor.camera_devices()
            if CAMERA_I2C_DEVICES:
                devices = [device for device in devices if device["dev"] in CAMERA_I2C_DEVICES]
        except Exception as e:
            self.set_state("error", f"Sensor check failed: {e}")
            return False
        if not devices:
            # Unknown camera type: do not block the start
            self.results = []
            self.set_state("no_device", "No known camera I2C device in the device tree, starting without sensor check")
            return True

        self.devices = {device["dev"]: device for device in devices}
        self.results = []
        for device in devices:
            do_bind = bind and now - self.last_bind >= BIND_RETRY_INTERVAL
            res = camera_sensor.check(device, do_bind=do_bind)
            if do_bind and (res["rebound"] or res["state"] == "bind_failed"):
                self.last_bind = now
            if res["rebound"]:
                logger.info(f"Self-heal: {res['message']}")

            if res["state"] == "waiting_sensor" and res["bound"]:
                since = self.missing_since.setdefault(device["dev"], now)
                if now - since >= SENSOR_LOST_TIMEOUT:
                    res.update(state="lost", message=f"Sensor of {device['dev']} lost (no answer for {now - since:.0f}s)")
            else:
                self.missing_since.pop(device["dev"], None)
            self.results.append(res)

        not_ready = [res for res in self.results if res["state"] != "ready"]
        if not_ready:
            self.set_state(not_ready[0]["state"], "; ".join(res["message"] for res in not_ready), devices=self.results)
            return False
        self.set_state("ready", "; ".join(res["message"] for res in self.results), devices=self.results)
        return True

    def ready_to_start(self, since):
        """Poll (with bind). True when all sensors are ready, or at least one
        is and the others did not answer within SENSOR_SETTLE_TIME after
        <since> (e.g. a port enabled in the device tree without a camera)."""
        if self.poll():
            return True
        return self.any_ready() and time.monotonic() - since >= SENSOR_SETTLE_TIME

    def wait_ready(self, timeout):
        start = time.monotonic()
        while time.monotonic() - start < timeout:
            if self.ready_to_start(start):
                return True
            time.sleep(SENSOR_POLL_INTERVAL)
        return False


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

        logger.info(f"FTDI Service started. Mode: {'SIMULATION' if SIMULATION_MODE else 'HARDWARE'}, interface: {CONTROL_INTERFACE}, start camera at startup: {START_CAMERA_AT_STARTUP}")

        hardware_failed = False

        if not SIMULATION_MODE:
            import serial as serial_module
            ser = None
            try:
                if CONTROL_INTERFACE == "gpio":
                    # Same interface as the serial port: rts = power OFF, cts = button
                    import gpio_control
                    ser = gpio_control.from_env()
                    logger.info(f"Using GPIOs: power GPIO{os.getenv('GPIO_POWER_PIN', 22)}, button GPIO{os.getenv('GPIO_BUTTON_PIN', 27)}")
                else:
                    ser = serial_module.Serial(SERIAL_PORT, baudrate=9600, timeout=1)
                    logger.info(f"Connected to hardware on {SERIAL_PORT}")

                # Initialize RTS LOW — camera on/streaming is the safe default
                ser.rts = False
                last_cts_state = ser.cts

                # Sensor is powered now: if it was not powered while booting, its
                # driver probe failed - bind it so the video device appears.
                watch = SensorWatch()
                if watch.wait_ready(SENSOR_READY_TIMEOUT):
                    logger.info(f"Sensor check at startup: {watch.health['message']}")
                else:
                    logger.warning(f"Sensor check at startup: not ready after {SENSOR_READY_TIMEOUT}s - {watch.health['message']}")

                # State machine states (RTS LOW = camera ON, RTS HIGH = camera OFF)
                STATE_UNKNOWN = "UNKNOWN"                    # Initial: querying actual camera state
                STATE_IDLE = "IDLE"                          # Camera off (RTS HIGH), waiting for button
                STATE_WAITING_START = "WAITING_START"        # RTS LOW, waiting for the sensor to answer on I2C
                STATE_RUNNING = "RUNNING"                    # Camera running (RTS LOW)
                STATE_WAITING_STOP = "WAITING_STOP"          # Sent stop, waiting for backend confirmation
                STATE_WAITING_START_CONFIRMED = "WAITING_START_CONFIRMED"  # Sent start, waiting for backend confirmation
                STATE_SENSOR_LOST = "SENSOR_LOST"            # Sensor lost while running: stop, restart when it answers again (RTS LOW)

                current_state = STATE_UNKNOWN
                state_unknown_start = time.monotonic()
                button_press_time = None
                start_requested_time = None  # First start_camera of the current start sequence
                start_sent_time = None       # Last (re)sent start_camera
                lost_time = None             # Sensor lost detected, stop_camera sent
                lost_stop_confirmed = False  # Backend confirmed the stop after the loss
                lost_stopped = False         # Camera stopped after the loss, waiting for the sensor
                last_monitor = 0.0           # Last sensor check while powered (RUNNING/IDLE)
                pending_toggle = False  # Set by Redis FTDI_CHANNEL to simulate a button press
                restart_after_stop = False   # Start pressed during WAITING_STOP

                def send_start():
                    nonlocal current_state, start_requested_time, start_sent_time, button_press_time
                    r.publish(CONTROL_CHANNEL, json.dumps({"command": "start_camera", "camera_id": 0}))
                    current_state = STATE_WAITING_START_CONFIRMED
                    start_requested_time = start_sent_time = time.monotonic()
                    button_press_time = None

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
                                    elif camera_status in ('stopped', 'stop') and START_CAMERA_AT_STARTUP:
                                        # Auto start: the power is still on (set LOW at startup), run
                                        # the normal start sequence - waits for the sensor on I2C, then
                                        # sends start_camera. The camera app waits for it in idle
                                        # (CAMERA_AUTOSTART=OFF).
                                        logger.info("Initial status: camera stopped - START_CAMERA_AT_STARTUP, starting it")
                                        ser.rts = False
                                        current_state = STATE_WAITING_START
                                        button_press_time = time.monotonic()
                                        watch.power_changed()
                                    elif camera_status in ('stopped', 'stop'):
                                        # IDLE always means power OFF: the backend decides by the
                                        # RTS key (HIGH = off) whether start/stop send a toggle, with
                                        # IDLE + power ON the frontend start would do nothing.
                                        # Stop first, do not just switch off: the camera app starts
                                        # streaming on its own at startup although the backend reports
                                        # "stopped". Cutting the power under a running stream makes it
                                        # restart, and its stream start on the unpowered sensor
                                        # crashes rp1-cfe (kernel oops in csi2_stop_channel).
                                        logger.info("Initial status: camera stopped - stopping it before setting RTS HIGH")
                                        r.publish(CONTROL_CHANNEL, json.dumps({"command": "stop_camera", "camera_id": 0}))
                                        current_state = STATE_WAITING_STOP
                                        button_press_time = time.monotonic()

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
                                    watch.power_changed()
                                    watch.set_state("powered_off", "Sensor power switched off")
                                    if restart_after_stop:
                                        restart_after_stop = False
                                        pending_toggle = True  # start sequence in this loop pass

                                elif current_state == STATE_SENSOR_LOST and camera_status in ('stopped', 'stop'):
                                    logger.info("Camera stop after sensor loss confirmed by backend")
                                    lost_stop_confirmed = True

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

                            elif current_state == STATE_WAITING_STOP:
                                # Start pressed while stopping: finish the stop (power off),
                                # then run a normal start sequence
                                logger.info("Button pressed while stopping - starting again after the stop")
                                restart_after_stop = True

                            elif current_state == STATE_IDLE:
                                logger.info(f"Button pressed - powering camera ON (RTS LOW), waiting up to {SENSOR_READY_TIMEOUT}s for the sensor on I2C...")
                                ser.rts = False  # Power camera ON
                                current_state = STATE_WAITING_START
                                button_press_time = time.monotonic()
                                watch.power_changed()
                                watch.set_state("waiting_sensor", "Sensor powered on, waiting for it to answer on I2C")

                            elif current_state == STATE_SENSOR_LOST:
                                logger.info("Button pressed while the sensor is lost - powering camera OFF (RTS HIGH)")
                                ser.rts = True
                                current_state = STATE_IDLE
                                watch.power_changed()
                                watch.set_state("powered_off", "Sensor power switched off")

                            elif current_state == STATE_RUNNING:
                                logger.info("Button pressed - initiating stop sequence, waiting for backend confirmation...")
                                r.publish(CONTROL_CHANNEL, json.dumps({"command": "stop_camera", "camera_id": 0}))
                                current_state = STATE_WAITING_STOP
                                button_press_time = time.monotonic()
                                # RTS stays LOW until backend confirms camera stopped

                        last_cts_state = current_cts

                        # Timeout fallback: if backend doesn't respond within 10s, assume camera is running
                        if current_state == STATE_UNKNOWN and time.monotonic() - state_unknown_start > 10.0:
                            logger.warning("No status response from backend within 10s - defaulting to RUNNING state (RTS stays LOW)")
                            current_state = STATE_RUNNING

                        # Start sequence: wait until the sensor answers on I2C (binds the
                        # driver if needed), then send the start signal
                        if current_state == STATE_WAITING_START and button_press_time:
                            waited = time.monotonic() - button_press_time
                            if watch.ready_to_start(button_press_time):
                                logger.info(f"Sensor ready after {waited:.1f}s ({watch.health['message']}) - sending start_camera signal")
                                send_start()
                            elif waited >= SENSOR_READY_TIMEOUT:
                                logger.error(f"Sensor not ready after {waited:.1f}s - not starting, setting RTS HIGH. Check cable and power, then press the button again")
                                watch.set_state("not_found", f"No sensor after {SENSOR_READY_TIMEOUT:.0f}s: {watch.health['message']}")
                                ser.rts = True  # IDLE = power off, the next start powers on and retries
                                current_state = STATE_IDLE
                                button_press_time = None
                                watch.power_changed()

                        # The camera app may not be up yet (e.g. restarting after the bind):
                        # resend the start signal until the backend confirms
                        if current_state == STATE_WAITING_START_CONFIRMED and start_requested_time:
                            now = time.monotonic()
                            if now - start_requested_time >= START_CONFIRM_TIMEOUT:
                                # The start may still go through late: stop first, the power
                                # goes off with the stop confirmation (see startup)
                                logger.error(f"No start confirmation within {START_CONFIRM_TIMEOUT}s - stopping, press the button to retry")
                                r.publish(CONTROL_CHANNEL, json.dumps({"command": "stop_camera", "camera_id": 0}))
                                current_state = STATE_WAITING_STOP
                                button_press_time = time.monotonic()
                                start_requested_time = start_sent_time = None
                            elif now - start_sent_time >= START_RETRY_INTERVAL:
                                logger.warning("Start not confirmed yet - resending start_camera signal")
                                r.publish(CONTROL_CHANNEL, json.dumps({"command": "start_camera", "camera_id": 0}))
                                start_sent_time = now

                        # No stop confirmation (camera app not answering): do not stay in
                        # WAITING_STOP forever (every further button press would be ignored),
                        # but keep the power ON - the stream may still run, see startup above.
                        # Back to RUNNING, the next press retries the stop.
                        if current_state == STATE_WAITING_STOP and button_press_time and time.monotonic() - button_press_time >= STOP_CONFIRM_TIMEOUT:
                            logger.error(f"No stop confirmation within {STOP_CONFIRM_TIMEOUT}s - power stays ON, back to RUNNING, press again to retry")
                            current_state = STATE_RUNNING
                            button_press_time = None
                            restart_after_stop = False

                        # Sensor monitor while powered: the driver stays bound when the
                        # sensor is lost, so check that the bound sensor still answers.
                        # IDLE: not streaming, poll() binds never bound sensors that answer.
                        # RUNNING: if no sensor answers anymore, stop the camera.
                        # A lost sensor that is still in use by another one is only
                        # reported (camera:health).
                        now = time.monotonic()
                        if current_state in (STATE_RUNNING, STATE_IDLE) and not ser.rts and now - last_monitor >= SENSOR_MONITOR_INTERVAL:
                            last_monitor = now
                            watch.poll(bind=current_state == STATE_IDLE)
                            if current_state == STATE_RUNNING and watch.lost() and not watch.any_ready():
                                logger.error(f"{watch.health['message']} - stopping camera, it restarts when the sensor answers again")
                                r.publish(CONTROL_CHANNEL, json.dumps({"command": "stop_camera", "camera_id": 0}))
                                current_state = STATE_SENSOR_LOST
                                lost_time = now
                                lost_stop_confirmed = lost_stopped = False

                        # Sensor lost: once the camera is stopped, wait until the sensor
                        # answers again (the driver is still bound), then restart
                        if current_state == STATE_SENSOR_LOST:
                            if not lost_stopped:
                                lost_stopped = lost_stop_confirmed or now - lost_time >= LOST_STOP_TIMEOUT
                            elif watch.poll() or watch.any_ready():
                                logger.info(f"Sensor back ({watch.health['message']}) - sending start_camera signal")
                                send_start()

                        # Publish current state to Redis keys (TTL=10s so keys expire if service dies)
                        r.set(FTDI_STATE_KEY, current_state, ex=10)
                        # The backend starts the camera directly when it reads LOW, else it
                        # sends a toggle. Report LOW only when RUNNING (power on, start
                        # confirmed): a direct start during a start/stop sequence would race
                        # the power switch, and a stream start on the unpowered sensor
                        # crashes rp1-cfe (kernel oops).
                        r.set(FTDI_RTS_KEY, "LOW" if current_state == STATE_RUNNING else "HIGH", ex=10)
                        r.set(CAMERA_HEALTH_KEY, json.dumps(watch.health), ex=10)

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
                            state_unknown_start = time.monotonic()
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
            last_press = time.monotonic()
            while True:
                message = pubsub.get_message(ignore_subscribe_messages=True)
                if message:
                    logger.info(f"HANDSHAKE RECEIVED: {message['data']}")

                if time.monotonic() - last_press > 15:
                    logger.info("SIMULATED BUTTON PRESS (Timer)")
                    r.publish(CONTROL_CHANNEL, json.dumps({"command": "TOGGLE", "camera_id": 0}))
                    last_press = time.monotonic()
                time.sleep(0.1)

    except Exception as e:
        logger.error(f"Critical Error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    run_ftdi_service()
