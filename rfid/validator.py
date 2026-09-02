# rfid/validator.py

import time
import logging
from datetime import datetime
from db.local_db import LocalDB
from db.azure_sync import sync_local_from_azure, push_access_requests, push_user_update
from lcd.lcd import LCD
from config.constants import MACHINE_ID
from relay.controller import RelayController
from utils.startup_check import startup_sequence
from config.constants import STATUS_IN_USE, LCD_LINE_DELAY

logger = logging.getLogger("validator")
lcd = LCD()
relay = RelayController()
db = LocalDB()

def validate_card(csu_id, uid_num):
    logger.info(f"[VALIDATOR] Card scanned: {csu_id}")
    user = db.get_user(csu_id)

    # CASE 1: Unknown or unauthorized user
    if not user or not db.has_permission(csu_id, MACHINE_ID):
        lcd.display("Access Denied", "Raising req",  color="red")
        time.sleep(3)
        if db.access_request_exists(csu_id, MACHINE_ID):
            lcd.display("Already sent", "Please wait", color="red")
            logger.info(f"[ACCESS] Request already exists for {csu_id}")
        else:
            db.insert_access_request(csu_id, MACHINE_ID, uid_fallback=uid_num)
            push_access_requests()
            lcd.display("Request raised", "Please wait", color="yellow")
            logger.info(f"[ACCESS] Request raised for {csu_id}")
        time.sleep(LCD_LINE_DELAY)

        # After request sync, re-sync system data
        startup_sequence()
        return None, None

    # CASE 2: Valid user with permission
    display_name = user["name"] if user["name"] else str(csu_id)

    # ENFORCE AFTER-HOURS CHECK
    lab_open, lab_close = db.get_open_close_times()
    if lab_open and lab_close:
        fmt = "%H:%M"
        try:
            now = datetime.now().time()
            open_time = datetime.strptime(lab_open, fmt).time()
            close_time = datetime.strptime(lab_close, fmt).time()

            # only check if not "After Hours"
            if not db.user_has_level(csu_id, "After Hours"):
                if not (open_time <= now <= close_time):
                    lcd.display("Access Denied", "Outside hours", color="red")
                    logger.warning(f"[ACCESS] Denied: {csu_id} outside lab hours")
                    time.sleep(LCD_LINE_DELAY)
                    return None, None
        except Exception as e:
            logger.error(f"[VALIDATOR] Time parse error: {e}")

    # ENSURE UID IS STORED
    if db.ensure_user_uid(csu_id, uid_num):
        logger.info(f"[SYNC] UID updated for {csu_id}, syncing to Azure")
        push_user_update(csu_id)

    logger.info(f"[ACCESS] Granted to {csu_id} - {display_name}")
    db.mark_user_active(csu_id)
    db.update_machine_status(MACHINE_ID, STATUS_IN_USE)
    db.update_machine_heartbeat(MACHINE_ID)
    relay.turn_on()
    return csu_id, display_name
