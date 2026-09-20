import os
import time
import socket
import subprocess
import logging
from config.constants import (
    LCD_MESSAGES,
    STATUS_MAINTENANCE,
    STATUS_NEUTRAL,
    MACHINE_ID,
    MACHINE_NAME,
    MACHINE_TYPE,
    LCD_LINE_DELAY,
    DB_ENV,
    DEVICE_ID as device_id
)
from db.azure_sync import sync_local_from_azure, push_machine_status


logger = logging.getLogger("startup")

def check_internet():
    try:
        return socket.gethostbyname("google.com")
    except:
        return False

def get_public_ip():
    try:
        result = subprocess.check_output("curl -s ifconfig.me", shell=True)
        return result.decode().strip()
    except:
        return "0.0.0.0"

def get_local_ip():
    """The address this Pi uses to reach the server: what the dashboard must call for /ping and
    /restart. (The public address is a shared NAT address the server cannot reach.)"""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect((DB_ENV["host"], DB_ENV["port"]))  # UDP: sends nothing, just picks the route
            return s.getsockname()[0]
    except Exception:
        return None

def startup_sequence(lcd, db):
    logger.info("[STEP] Starting system checks...")

    if not check_internet():
        lcd.display("\n".join(LCD_MESSAGES["internet_error"]), color="red")
        logger.error("[FAIL] No Internet")
        return False

    logger.info("[PASS] Internet check passed.")
    logger.info(f"[PASS] Public IP: {get_public_ip()}")
    device_ip = get_local_ip() or get_public_ip()
    logger.info(f"[PASS] Device IP (reported to dashboard): {device_ip}")

    try:
        lcd.display("Syncing online")
        sync_local_from_azure()
        logger.info("[PASS] Server sync complete.")
    except Exception as e:
        lcd.display("\n".join(LCD_MESSAGES["db_error"]), color="red")
        logger.error(f"[ERROR] Server sync failed: {e}")
        return False

    machine = db.get_machine(MACHINE_ID)
    if not machine:
        lcd.display(f"Machine {MACHINE_ID}", "not registered", color="red")
        db.insert_machine_if_missing(MACHINE_ID, MACHINE_NAME, MACHINE_TYPE)
        push_machine_status(db, MACHINE_ID)
        logger.warning(f"[WARN] Machine {MACHINE_ID} not found. Inserting default.")

    machine = db.get_machine(MACHINE_ID)
    if machine["machine_status"] == STATUS_MAINTENANCE:
        lcd.display("\n".join(LCD_MESSAGES["maintenance"]), color="yellow")
        logger.warning("[HALT] Machine in maintenance mode.")
        return False

    db.update_machine_status(MACHINE_ID, STATUS_NEUTRAL)
    db.update_machine_heartbeat(MACHINE_ID)
    db.update_machine_device(MACHINE_ID, device_id)
    logger.info(f"[PASS] Machine {MACHINE_ID} status updated to neutral.")
    logger.info(f"[PASS] Machine heartbeat updated.")

    db.update_machine_ip(MACHINE_ID, device_ip)
    push_machine_status(db, MACHINE_ID)
    logger.info(f"[PASS] Machine Status updated")

    lcd.display(*LCD_MESSAGES["start"])
    time.sleep(2)
    lcd.display(*LCD_MESSAGES["startup_next"])

    time.sleep(LCD_LINE_DELAY)
    return True
