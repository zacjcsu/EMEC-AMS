import time
import uuid
import logging
from config.constants import MACHINE_ID, CARD_GRACE_PERIOD_DEFAULT
from db.azure_sync import sync_session_to_azure, push_user_status, push_machine_status
from config.constants import STATUS_NEUTRAL, STATUS_IN_USE, LCD_LINE_DELAY

logger = logging.getLogger("session")

# Screen text when a running session is ended by the server (16 chars per line).
REVOKED_MESSAGES = {
    "estop": ("EMERGENCY", "SHUTDOWN"),
    "outside_hours": ("Lab closed", "Session ended"),
    "group_disabled": ("Access revoked", "Account locked"),
    "no_permission": ("Access revoked", "No permission"),
    "unknown_user": ("Access revoked", "Unknown user"),
}

class SessionManager:
    def __init__(self, db, lcd, relay, lockout=None):
        self.lockout = lockout
        self.db = db
        self.lcd = lcd
        self.relay = relay
        self._reset_session_state()

    def _reset_session_state(self):
        self.active_session_id = None
        self.active_csu_id = None
        self.session_start_time = None
        self.display_name = None
        if self.lockout:
            self.lockout.unwatch()

    def _show(self, line1, line2, color, delay=0):
        self.lcd.display(line1, line2, color=color)
        if delay:
            time.sleep(delay)

    def _sync_machine_status(self, status, csu_id):
        self.db.update_machine_status(MACHINE_ID, status)
        self.db.update_machine_heartbeat(MACHINE_ID)
        push_user_status(self.db, csu_id)
        push_machine_status(self.db, MACHINE_ID)

    def start_session(self, csu_id, display_name):
        if not self.active_session_id:
            self.active_session_id = str(uuid.uuid4())
            self.session_start_time = time.time()
            self.db.mark_user_active(csu_id)
            self.db.insert_session(self.active_session_id, csu_id, MACHINE_ID)
            logger.info(f"[SESSION] Started: {display_name} ({csu_id}), session_id: {self.active_session_id}")
        else:
            logger.info("[SESSION] Resumed session within grace period.")

        self.active_csu_id = csu_id
        self.display_name = display_name
        if self.lockout:
            self.lockout.watch(csu_id)
        self._sync_machine_status(STATUS_IN_USE, csu_id)

        self.relay.turn_on()
        self._show(display_name[:16], "in use", color="green")

    def _lockout_reason(self):
        """None, 'estop', or the server's reason the signed-in user lost access."""
        if not self.lockout:
            return None
        if self.lockout.estop_active:
            return "estop"
        return self.lockout.revoked_reason

    def _end_for_lockout(self, reason):
        logger.warning(f"[SESSION] Ending session: {reason}.")
        line1, line2 = REVOKED_MESSAGES.get(reason, ("Access revoked", str(reason)))
        self._show(line1, line2, color="red", delay=LCD_LINE_DELAY)
        self.force_end_session()

    def wait_for_card_removal(self, reader):
        absence_start = None
        while True:
            reason = self._lockout_reason()
            if reason:
                self._end_for_lockout(reason)
                break
            scan = reader.read_card()
            if scan:
                uid, csu_id = scan
                if csu_id == self.active_csu_id:
                    absence_start = None
                else:
                    logger.info("[SESSION] New card detected mid-session.")
                    self._show("New card mid-sesh", "Resetting...", color="red", delay=LCD_LINE_DELAY)
                    self.force_end_session()
                    break
            else:
                if absence_start is None:
                    absence_start = time.time()
                elif time.time() - absence_start >= 3:
                    self._show("Card removed", "Waiting for reinsert", color="yellow")
                    break
            time.sleep(0.5)

    def handle_grace_period(self, reader):
        grace_period = int(self.db.get_setting("grace_period_seconds", default=CARD_GRACE_PERIOD_DEFAULT))
        end_time = time.time() + grace_period
        while time.time() < end_time:
            reason = self._lockout_reason()
            if reason:
                self._end_for_lockout(reason)
                return reason
            remaining = int(end_time - time.time())
            self.lcd.display("Remove detected", f"Reinsert: {remaining}s", color="yellow")

            scan = reader.read_card()
            if scan:
                uid, csu_id = scan
                if csu_id == self.active_csu_id:
                    self._show("Session", "resumed", color="green", delay=1)
                    self.start_session(csu_id, self.display_name)
                    return "resumed"
                else:
                    self._show("New card at grace", "Resetting...", color="red", delay=LCD_LINE_DELAY)
                    self.force_end_session()
                    return "new_card"
            time.sleep(1)

        self.force_end_session()
        logger.info("[SESSION] Ended after grace period.")
        return "timeout"

    def force_end_session(self):
        if not self.active_session_id:
            return

        end_time = time.time()
        duration_sec = int(end_time - self.session_start_time)
        duration_min = max(0, round(duration_sec / 60))

        self.db.end_session(self.active_session_id)
        self.db.mark_user_inactive(self.active_csu_id)
        self._sync_machine_status(STATUS_NEUTRAL, self.active_csu_id)

        sync_session_to_azure(self.active_session_id)
        logger.info(f"[SESSION] Ended: {self.display_name} ({self.active_csu_id}), duration: {duration_min} min")

        self._show("Session", "ended", color="red", delay=1)

        self._reset_session_state()
        self.relay.turn_off()
