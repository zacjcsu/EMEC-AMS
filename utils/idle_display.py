import time
from config.constants import (
    LCD_MESSAGES, IDLE_SCAN_SCREEN_SECONDS, IDLE_LAST_USED_SCREEN_SECONDS
)


class IdleDisplay:
    """While nobody is on the machine, alternate the scan prompt with who used it last, so the
    last user can be read off the machine without opening the dashboard."""

    def __init__(self, lcd, db, lockout=None):
        self.lockout = lockout
        self.showing_lockout = False
        self.lcd = lcd
        self.db = db
        self.reset()

    def reset(self):
        """Call right after the scan prompt has been put on the screen by something else."""
        self.showing_last = False
        self.since = time.monotonic()

    def _lockout_message(self):
        """(line1, line2, color) while the machine is locked out, else None. Emergency shutdown (lab-wide)
        takes priority over maintenance (this machine only) when, unusually, both are active."""
        if not self.lockout:
            return None
        if self.lockout.estop_active:
            return "EMERGENCY", "SHUTDOWN", "red"
        if self.lockout.maintenance_active:
            return LCD_MESSAGES["maintenance"][0], LCD_MESSAGES["maintenance"][1], "yellow"
        return None

    def tick(self):
        msg = self._lockout_message()
        if msg:
            if not self.showing_lockout:
                self.lcd.display(msg[0], msg[1], color=msg[2])
                self.showing_lockout = True
            return
        if self.showing_lockout:
            self.showing_lockout = False
            self.lcd.display(*LCD_MESSAGES["startup_next"])
            self.reset()
            return
        now = time.monotonic()
        if not self.showing_last:
            if now - self.since >= IDLE_SCAN_SCREEN_SECONDS:
                self.since = now
                name = self.db.get_last_user()
                if name:
                    self.lcd.display("Last Used:", name)
                    self.showing_last = True
        elif now - self.since >= IDLE_LAST_USED_SCREEN_SECONDS:
            self.lcd.display(*LCD_MESSAGES["startup_next"])
            self.showing_last = False
            self.since = now
