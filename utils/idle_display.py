import time
from config.constants import (
    LCD_MESSAGES, IDLE_SCAN_SCREEN_SECONDS, IDLE_LAST_USED_SCREEN_SECONDS, IDLE_MESSAGE_SCREEN_SECONDS
)


class IdleDisplay:
    """While nobody is on the machine, rotate the scan prompt, who used it last and the dashboard's message if
    there is one, so they can be read off the machine without opening the dashboard."""

    def __init__(self, lcd, db, lockout=None):
        self.lockout = lockout
        self.lcd = lcd
        self.db = db
        self.reset()

    def reset(self):
        """Call right after something else has drawn on the screen."""
        self.screen = "scan"
        self.shown_lockout = None   # the lockout screen currently drawn
        self.since = time.monotonic()

    def _message(self):
        return self.lockout.message if self.lockout else None

    def _lockout_message(self):
        """(line1, line2, color) while the machine is locked out, else None. Emergency shutdown (lab-wide)
        takes priority over maintenance (this machine only) when, unusually, both are active."""
        if not self.lockout:
            return None
        if self.lockout.estop_active:
            return "EMERGENCY", "SHUTDOWN", "red"
        if self.lockout.maintenance_active:
            message = self._message()
            if message:
                return message[0], message[1], "yellow"
            return LCD_MESSAGES["maintenance"][0], LCD_MESSAGES["maintenance"][1], "yellow"
        return None

    def _show(self, screen, *lines, color="white"):
        self.lcd.display(*lines, color=color)
        self.screen = screen
        self.since = time.monotonic()

    def tick(self):
        msg = self._lockout_message()
        if msg:
            if msg != self.shown_lockout:     # also redraws when the message is changed while locked
                self.lcd.display(msg[0], msg[1], color=msg[2])
                self.shown_lockout = msg
            return
        if self.shown_lockout:
            self.lcd.display(*LCD_MESSAGES["startup_next"])
            self.reset()
            return
        elapsed = time.monotonic() - self.since
        if self.screen == "scan" and elapsed >= IDLE_SCAN_SCREEN_SECONDS:
            name = self.db.get_last_user()
            if name:
                self._show("last", "Last Used:", name)
            elif self._message():
                self._show("message", *self._message(), color="yellow")
            else:
                self.since = time.monotonic()
        elif self.screen == "last" and elapsed >= IDLE_LAST_USED_SCREEN_SECONDS:
            if self._message():
                self._show("message", *self._message(), color="yellow")
            else:
                self._show("scan", *LCD_MESSAGES["startup_next"])
        elif self.screen == "message" and elapsed >= IDLE_MESSAGE_SCREEN_SECONDS:
            self._show("scan", *LCD_MESSAGES["startup_next"])
