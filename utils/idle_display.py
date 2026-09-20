import time
from config.constants import (
    LCD_MESSAGES, IDLE_SCAN_SCREEN_SECONDS, IDLE_LAST_USED_SCREEN_SECONDS
)


class IdleDisplay:
    """While nobody is on the machine, alternate the scan prompt with who used it last, so the
    last user can be read off the machine without opening the dashboard."""

    def __init__(self, lcd, db, lockout=None):
        self.lockout = lockout
        self.showing_estop = False
        self.lcd = lcd
        self.db = db
        self.reset()

    def reset(self):
        """Call right after the scan prompt has been put on the screen by something else."""
        self.showing_last = False
        self.since = time.monotonic()

    def tick(self):
        if self.lockout and self.lockout.estop_active:
            if not self.showing_estop:
                self.lcd.display("EMERGENCY", "SHUTDOWN", color="red")
                self.showing_estop = True
            return
        if self.showing_estop:
            self.showing_estop = False
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
