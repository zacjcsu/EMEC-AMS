# Front-panel status LEDs on the rev A HAT.
#
# D1 reader activity (GPIO23, physical 16) and D2 heartbeat (GPIO24,
# physical 18) are driven from here. D3 relay and D4 3V3 are wired to the
# relay drive net and the 3.3V rail respectively and need no code.
#
# Both LEDs are anode-to-GPIO through a 220R resistor to ground, so HIGH is on.

import RPi.GPIO as GPIO
import threading
import time
from config.constants import (
    LED_READER_PIN,
    LED_HEARTBEAT_PIN,
    HEARTBEAT_INTERVAL,
    READER_BLINK_DURATION,
)


class StatusLEDs:
    def __init__(self):
        GPIO.setwarnings(False)
        GPIO.setmode(GPIO.BOARD)
        GPIO.setup(LED_READER_PIN, GPIO.OUT, initial=GPIO.LOW)
        GPIO.setup(LED_HEARTBEAT_PIN, GPIO.OUT, initial=GPIO.LOW)
        self._stop = threading.Event()
        threading.Thread(target=self._heartbeat, daemon=True).start()

    def _heartbeat(self):
        # A thread, not a toggle in the main loop: phases 3 to 5 block for the
        # whole session, which is exactly when the heartbeat needs to be moving.
        state = False
        while not self._stop.is_set():
            state = not state
            GPIO.output(LED_HEARTBEAT_PIN, state)
            self._stop.wait(HEARTBEAT_INTERVAL)

    def reader_blink(self):
        """Non-blocking pulse on D1."""
        threading.Thread(target=self._blink, daemon=True).start()

    def _blink(self):
        GPIO.output(LED_READER_PIN, GPIO.HIGH)
        time.sleep(READER_BLINK_DURATION)
        GPIO.output(LED_READER_PIN, GPIO.LOW)

    def stop(self):
        """Stop the heartbeat and drive both LEDs off.

        Writes the pins here rather than leaving it to the thread, which is a
        daemon and may never get another slot before the interpreter exits.
        """
        self._stop.set()
        GPIO.output(LED_HEARTBEAT_PIN, GPIO.LOW)
        GPIO.output(LED_READER_PIN, GPIO.LOW)
