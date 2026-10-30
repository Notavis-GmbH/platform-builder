"""
Camera sensor readiness check and driver bind for the FTDI start sequence.

After the sensor power is switched on, the sensor is polled over I2C until it
answers (ported from produktionssetup-raspi/sensor_probe.py):

  VC MIPI module   microcontroller at 0x10, descriptor at register 0x1000
  blueline module  Sony sensor at 0x1a with chip ID in 0x4d1c (IMX678 0x02a6,
                   IMX662 0x0296), onsemi sensor at 0x28 with chip ID in
                   0x3000 (AR0246 0x1f56)

A Sony sensor in standby reads chip ID 0 (freshly powered). Then standby is
left for the ID read and the sensor stays out of standby: the IMX678 needs
"standby cancel" before its registers are written at stream start, otherwise
it gives no MIPI output after a power cycle (black image).

If the sensor was not powered while booting, its driver probe failed and no
video device exists. Once the sensor answers, the I2C device is bound to its
driver again (echo <dev> > /sys/bus/i2c/drivers/<driver>/bind), which also
lets the CSI receiver register its video nodes.

Never unbind a camera device (/sys/bus/i2c/drivers/<driver>/unbind): rp1-cfe
does not support a sensor that is bound again after an unbind - it registers
its video devices a second time ("Rejecting subdev ... Already set!!",
kobject warning) and the camera only works again after a reboot. A bound
driver keeps working when the sensor is repowered, so only devices that were
never bound (probe failed at boot) are bound.

The I2C transfers use the I2C_RDWR ioctl directly (no i2c-tools/smbus2 in
the container). Like 'i2ctransfer -f' it also works on addresses claimed by a
driver. Needs /dev/i2c-* and a writable /sys (privileged container).

Usage (diagnostics):
    python3 camera_sensor.py           check all camera devices
    python3 camera_sensor.py --bind    check and bind unbound devices
"""

import ctypes
import fcntl
import os
import re
import sys
import time
from pathlib import Path

I2C_DEVICES = Path("/sys/bus/i2c/devices")
I2C_DRIVERS = Path("/sys/bus/i2c/drivers")

I2C_RDWR = 0x0707
I2C_M_RD = 0x0001

VC_MOD_ADDR = 0x10
VC_DESC_BASE = 0x1000

# Camera I2C devices of the device tree: compatible -> driver name
CAMERA_COMPAT_RE = re.compile(r"^(vc,vc_mipi_camera|[a-z]+,(imx678|imx662|ar0246)(?:-aa[mq]r)?)$")
DRIVER_OF_MODEL = {"vc_mipi_camera": "vc_mipi_camera", "imx678": "imx678", "imx662": "imx678", "ar0246": "ar0246"}

# blueline sensors by I2C address: (chip ID register, byte order,
# {chip ID: model}, standby register or None). The Sony ID registers only
# answer 80 ms after leaving standby (0x3000: 1 standby, 0 operating).
BLUELINE_SENSORS = {
    0x1a: (0x4d1c, "little", {0x02a6: "IMX678", 0x0296: "IMX662"}, 0x3000),
    0x28: (0x3000, "big", {0x1f56: "AR0246"}, None),
}
STANDBY_EXIT_DELAY_S = 0.08


class _I2cMsg(ctypes.Structure):
    _fields_ = [
        ("addr", ctypes.c_uint16),
        ("flags", ctypes.c_uint16),
        ("len", ctypes.c_uint16),
        ("buf", ctypes.POINTER(ctypes.c_uint8)),
    ]


class _I2cRdwrData(ctypes.Structure):
    _fields_ = [("msgs", ctypes.POINTER(_I2cMsg)), ("nmsgs", ctypes.c_uint32)]


def _transfer(bus, addr, write, read_len=0):
    """Write <write> and optionally read <read_len> bytes with a repeated
    start. Returns the read bytes (b"" for a pure write), None on error."""
    wbuf = (ctypes.c_uint8 * len(write))(*write)
    msgs = [_I2cMsg(addr, 0, len(write), ctypes.cast(wbuf, ctypes.POINTER(ctypes.c_uint8)))]
    rbuf = None
    if read_len:
        rbuf = (ctypes.c_uint8 * read_len)()
        msgs.append(_I2cMsg(addr, I2C_M_RD, read_len, ctypes.cast(rbuf, ctypes.POINTER(ctypes.c_uint8))))
    msg_array = (_I2cMsg * len(msgs))(*msgs)
    data = _I2cRdwrData(msg_array, len(msgs))
    try:
        fd = os.open(f"/dev/i2c-{bus}", os.O_RDWR)
    except OSError:
        return None
    try:
        # Passed as buffer: an int argument is limited to 32 bit
        fcntl.ioctl(fd, I2C_RDWR, data)
    except OSError:
        return None
    finally:
        os.close(fd)
    return bytes(rbuf) if rbuf is not None else b""


def i2c_read(bus, addr, reg, length=1):
    """Read <length> bytes from a 16-bit register address, None on error."""
    return _transfer(bus, addr, [reg >> 8, reg & 0xff], length)


def i2c_write(bus, addr, reg, value):
    """Write one byte to a 16-bit register address. True on success."""
    return _transfer(bus, addr, [reg >> 8, reg & 0xff, value]) is not None


def camera_devices():
    """Camera I2C devices of the device tree (bound or not), e.g.
    [{"dev": "10-001a", "bus": 10, "addr": 0x1a, "model": "imx678", "driver": "imx678"}]"""
    devices = []
    if not I2C_DEVICES.is_dir():
        return devices
    for dev in sorted(I2C_DEVICES.iterdir()):
        try:
            compatible = (dev / "of_node" / "compatible").read_bytes().split(b"\0")[0].decode()
        except OSError:
            continue
        m = CAMERA_COMPAT_RE.match(compatible)
        if not m:
            continue
        model = m.group(2) or "vc_mipi_camera"
        bus, addr = dev.name.split("-")
        devices.append({
            "dev": dev.name,
            "bus": int(bus),
            "addr": int(addr, 16),
            "model": model,
            "driver": os.getenv("CAMERA_I2C_DRIVER") or DRIVER_OF_MODEL[model],
        })
    return devices


def is_bound(device):
    return (I2C_DEVICES / device["dev"] / "driver").exists()


def _read_id_from_standby(bus, addr, reg, standby_reg):
    """Chip ID of a sensor in standby: leave standby and read it. The sensor
    stays out of standby; only if the ID cannot be read, standby is switched
    on again."""
    standby = i2c_read(bus, addr, standby_reg)
    if standby is None or standby[0] & 0x01 == 0 or not i2c_write(bus, addr, standby_reg, 0x00):
        return None
    time.sleep(STANDBY_EXIT_DELAY_S)
    data = i2c_read(bus, addr, reg, 2)
    if data is None or not any(data):
        i2c_write(bus, addr, standby_reg, standby[0])
    return data


def probe_sensor(device):
    """Sensor name if the sensor of <device> answers over I2C, else None."""
    bus = device["bus"]
    if device["model"] == "vc_mipi_camera":
        return "VC MIPI module" if i2c_read(bus, VC_MOD_ADDR, VC_DESC_BASE) is not None else None

    sensor = BLUELINE_SENSORS.get(device["addr"])
    if sensor is None:
        return None
    reg, byteorder, chip_ids, standby_reg = sensor
    data = i2c_read(bus, device["addr"], reg, 2)
    if data is None:
        return None
    chip_id = int.from_bytes(data, byteorder)
    if chip_id == 0 and standby_reg is not None:
        data = _read_id_from_standby(bus, device["addr"], reg, standby_reg)
        chip_id = int.from_bytes(data, byteorder) if data else 0
    return chip_ids.get(chip_id)


def bind(device):
    """Bind <device> to its driver. Returns None on success, else the error."""
    if is_bound(device):
        return None
    bind_file = I2C_DRIVERS / device["driver"] / "bind"
    if not bind_file.exists():
        return f"driver {device['driver']} not loaded"
    try:
        bind_file.write_text(device["dev"])
    except OSError as e:
        return f"bind {device['dev']} to {device['driver']} failed: {e.strerror}"
    return None if is_bound(device) else f"{device['dev']} not bound after bind"


def check(device, do_bind=True):
    """One readiness check of a camera device, does not block.

    Returns {"state": ..., "dev", "driver", "sensor", "message"} with state
      waiting_sensor  sensor does not answer (yet)
      bind_failed     sensor answers, but the driver bind failed
      ready           sensor answers and the driver is bound
    "rebound" is True if the device was bound by this call. A bound device
    whose sensor does not answer is waiting_sensor with "bound" True."""
    result = {"dev": device["dev"], "driver": device["driver"], "sensor": None,
              "bound": is_bound(device), "rebound": False}
    sensor = probe_sensor(device)
    if sensor is None:
        result.update(state="waiting_sensor", message=f"No answer from the sensor of {device['dev']}")
        return result
    result["sensor"] = sensor

    if result["bound"]:
        result.update(state="ready", message=f"{sensor} ready ({device['dev']})")
        return result
    if not do_bind:
        result.update(state="bind_failed", message=f"{sensor} answers, but {device['dev']} is not bound")
        return result

    error = bind(device)
    if error:
        result.update(state="bind_failed", message=error)
        return result
    result.update(state="ready", bound=True, rebound=True, message=f"{sensor} ready, {device['dev']} bound to {device['driver']}")
    return result


if __name__ == "__main__":
    do_bind = "--bind" in sys.argv[1:]
    devices = camera_devices()
    if not devices:
        print("No camera I2C device in the device tree")
    for d in devices:
        print({**d, "bound": is_bound(d)}, "->", check(d, do_bind=do_bind))
