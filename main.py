#!/usr/bin/env python

from utils import hardware_stubs  # noqa: F401  (must be imported first, see utils/hardware_stubs.py)
from utils.startup_check import startup_sequence
from rfid.reader import RFIDReader
from rfid.validator import validate_card
from relay.session_manager import SessionManager
from relay.controller import RelayController
from lcd.lcd import LCD
import time
import signal
import sys
from db.local_db import LocalDB
from config.constants import CARD_POLL_INTERVAL, MACHINE_ID, STATUS_OFFLINE
from db.azure_sync import push_machine_status
import logging
from logging.handlers import TimedRotatingFileHandler
import os

os.makedirs("logs", exist_ok=True)
file_handler = TimedRotatingFileHandler(
    "logs/sync.log", when="D", interval=1, backupCount=7
)
# Plain stdout handler: systemd captures the service's stdout into the
# journal (journalctl -u emec-ams), so this is what gets it there.
stream_handler = logging.StreamHandler()
formatter = logging.Formatter(
    '[%(asctime)s] %(levelname)s [%(name)s]: %(message)s',
    datefmt="%Y-%m-%d %H:%M:%S"
)
file_handler.setFormatter(formatter)
stream_handler.setFormatter(formatter)
logging.basicConfig(level=logging.INFO, handlers=[file_handler, stream_handler])
logger = logging.getLogger("main")
logger.info("[STARTUP] EMEC-AMS starting (machine_id=%s)", MACHINE_ID)

lcd = LCD()
db = LocalDB()
relay = RelayController()
reader = RFIDReader()
session_mgr = SessionManager(db, lcd, relay)

def exit_handler(sig, frame):
    lcd.display("Shutting down...")
    db.update_machine_status(MACHINE_ID, STATUS_OFFLINE)
    db.update_machine_heartbeat(MACHINE_ID)
    push_machine_status(db, MACHINE_ID)
    lcd.clear()
    sys.exit(0)

signal.signal(signal.SIGINT, exit_handler)
signal.signal(signal.SIGTERM, exit_handler)

def main():
    while True:
        try:
            if not startup_sequence(lcd, db):
                time.sleep(5)
                continue

            while True:
                scan = reader.read_card()
                if scan:
                    uid_num, csu_id = scan
                    validated_csu_id, display_name = validate_card(csu_id, uid_num, db, lcd, relay)
                    if validated_csu_id:
                        break
                    else:
                        startup_sequence(lcd, db)
                time.sleep(CARD_POLL_INTERVAL)

            session_mgr.start_session(validated_csu_id, display_name)
            session_mgr.wait_for_card_removal(reader)
            session_mgr.handle_grace_period(reader)
        except Exception:
            logger.exception("[MAIN] Unhandled error in main loop; recovering.")
            time.sleep(5)

if __name__ == "__main__":
    main()
