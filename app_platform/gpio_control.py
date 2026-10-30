"""
Camera power output and button input on Raspberry Pi header GPIOs, as an
alternative to the FTDI adapter (CONTROL_INTERFACE=gpio in ftdi_service.py).

GpioControl has the same interface as the serial port used by the FTDI state
machine, so it can replace it unchanged:

    rts = False   camera power ON  (power pin at its "on" level)
    rts = True    camera power OFF
    cts           True while the button is pressed (debounced)

A GPIO can only drive a few mA: switch the camera supply with a transistor
or load switch, the pin only gives the 3.3 V control signal.

Uses the GPIO character device (v2 uAPI) directly via ioctl, no libgpiod or
RPi.GPIO needed. Needs /dev/gpiochipN (privileged container). On the
Raspberry Pi 5 / CM5 the header pins are lines 0-27 of gpiochip0
(pinctrl-rp1), the line number is the BCM GPIO number.

Usage (diagnostics):
    python3 gpio_control.py            show the button state
    python3 gpio_control.py on|off     switch the power pin
"""

import ctypes
import fcntl
import os
import sys
import time

GPIO_V2_LINES_MAX = 64
GPIO_MAX_NAME_SIZE = 32
GPIO_V2_LINE_NUM_ATTRS_MAX = 10

GPIO_V2_LINE_FLAG_ACTIVE_LOW = 1 << 1
GPIO_V2_LINE_FLAG_INPUT = 1 << 2
GPIO_V2_LINE_FLAG_OUTPUT = 1 << 3
GPIO_V2_LINE_FLAG_BIAS_PULL_UP = 1 << 8
GPIO_V2_LINE_FLAG_BIAS_PULL_DOWN = 1 << 9
GPIO_V2_LINE_FLAG_BIAS_DISABLED = 1 << 10

GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES = 2


class _LineAttribute(ctypes.Structure):
    # union of flags (u64), values (u64), debounce_period_us (u32)
    _fields_ = [("id", ctypes.c_uint32), ("padding", ctypes.c_uint32), ("value", ctypes.c_uint64)]


class _LineConfigAttribute(ctypes.Structure):
    _fields_ = [("attr", _LineAttribute), ("mask", ctypes.c_uint64)]


class _LineConfig(ctypes.Structure):
    _fields_ = [
        ("flags", ctypes.c_uint64),
        ("num_attrs", ctypes.c_uint32),
        ("padding", ctypes.c_uint32 * 5),
        ("attrs", _LineConfigAttribute * GPIO_V2_LINE_NUM_ATTRS_MAX),
    ]


class _LineRequest(ctypes.Structure):
    _fields_ = [
        ("offsets", ctypes.c_uint32 * GPIO_V2_LINES_MAX),
        ("consumer", ctypes.c_char * GPIO_MAX_NAME_SIZE),
        ("config", _LineConfig),
        ("num_lines", ctypes.c_uint32),
        ("event_buffer_size", ctypes.c_uint32),
        ("padding", ctypes.c_uint32 * 5),
        ("fd", ctypes.c_int32),
    ]


class _LineValues(ctypes.Structure):
    _fields_ = [("bits", ctypes.c_uint64), ("mask", ctypes.c_uint64)]


def _iowr(nr, struct):
    return (3 << 30) | (ctypes.sizeof(struct) << 16) | (0xB4 << 8) | nr


GPIO_V2_GET_LINE_IOCTL = _iowr(0x07, _LineRequest)
GPIO_V2_LINE_GET_VALUES_IOCTL = _iowr(0x0E, _LineValues)
GPIO_V2_LINE_SET_VALUES_IOCTL = _iowr(0x0F, _LineValues)

BIAS_FLAGS = {
    "pull-up": GPIO_V2_LINE_FLAG_BIAS_PULL_UP,
    "pull-down": GPIO_V2_LINE_FLAG_BIAS_PULL_DOWN,
    "disabled": GPIO_V2_LINE_FLAG_BIAS_DISABLED,
    "none": 0,
}


class GpioLine:
    """One requested GPIO line. Values are logical: with active_low the
    kernel inverts them, so value True is always "active"."""

    def __init__(self, chip, line, output, consumer, active_low=False, bias="none", initial=False):
        flags = GPIO_V2_LINE_FLAG_OUTPUT if output else GPIO_V2_LINE_FLAG_INPUT
        if active_low:
            flags |= GPIO_V2_LINE_FLAG_ACTIVE_LOW
        if not output:
            flags |= BIAS_FLAGS[bias]

        req = _LineRequest()
        req.offsets[0] = line
        req.num_lines = 1
        req.consumer = consumer.encode()[:GPIO_MAX_NAME_SIZE - 1]
        req.config.flags = flags
        if output:
            # Set the level in the same request, so the pin never glitches
            req.config.num_attrs = 1
            req.config.attrs[0].attr.id = GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES
            req.config.attrs[0].attr.value = 1 if initial else 0
            req.config.attrs[0].mask = 1

        chip_fd = os.open(chip, os.O_RDWR)
        try:
            fcntl.ioctl(chip_fd, GPIO_V2_GET_LINE_IOCTL, req)
        except OSError as e:
            raise OSError(e.errno, f"Cannot request {chip} line {line}: {e.strerror} (in use by another process?)") from None
        finally:
            os.close(chip_fd)
        self.fd = req.fd
        self.line = line

    def get(self):
        values = _LineValues(0, 1)
        fcntl.ioctl(self.fd, GPIO_V2_LINE_GET_VALUES_IOCTL, values)
        return bool(values.bits & 1)

    def set(self, value):
        fcntl.ioctl(self.fd, GPIO_V2_LINE_SET_VALUES_IOCTL, _LineValues(1 if value else 0, 1))

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


class GpioControl:
    """Camera power and button on GPIOs with the serial port interface of the
    FTDI state machine (rts = power OFF, cts = button pressed)."""

    def __init__(self, chip="/dev/gpiochip0", power_pin=22, button_pin=27,
                 power_on_high=True, button_active_low=True, button_bias="pull-up"):
        # Power ON at start, like the FTDI default (RTS LOW = camera ON)
        self._power = GpioLine(chip, power_pin, output=True, consumer="camera-power",
                               active_low=not power_on_high, initial=True)
        try:
            self._button = GpioLine(chip, button_pin, output=False, consumer="camera-button",
                                    active_low=button_active_low, bias=button_bias)
        except OSError:
            self._power.close()
            raise
        self._stable = self._button.get()
        self._last_raw = self._stable

    @property
    def rts(self):
        return not self._power.get()

    @rts.setter
    def rts(self, power_off):
        self._power.set(not power_off)

    @property
    def cts(self):
        # Debounce: a new level counts once it was read twice in a row
        # (the state machine polls every 50 ms)
        raw = self._button.get()
        if raw == self._last_raw:
            self._stable = raw
        self._last_raw = raw
        return self._stable

    def close(self):
        self._button.close()
        self._power.close()


def from_env():
    return GpioControl(
        chip=os.getenv("GPIO_CHIP", "/dev/gpiochip0"),
        power_pin=int(os.getenv("GPIO_POWER_PIN", 22)),
        button_pin=int(os.getenv("GPIO_BUTTON_PIN", 27)),
        power_on_high=os.getenv("GPIO_POWER_ON_LEVEL", "high").lower() == "high",
        button_active_low=os.getenv("GPIO_BUTTON_ACTIVE", "low").lower() == "low",
        button_bias=os.getenv("GPIO_BUTTON_BIAS", "pull-up").lower(),
    )


if __name__ == "__main__":
    ctl = from_env()
    if sys.argv[1:] in (["on"], ["off"]):
        ctl.rts = sys.argv[1] == "off"
        print(f"Power {'OFF' if ctl.rts else 'ON'}")
        input("Press Enter to release the pins...")
    else:
        print("Button state (Ctrl+C to stop):")
        last = None
        try:
            while True:
                pressed = ctl.cts
                if pressed != last:
                    print("pressed" if pressed else "released")
                    last = pressed
                time.sleep(0.05)
        except KeyboardInterrupt:
            pass
    ctl.close()
