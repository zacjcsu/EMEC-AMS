import time
import logging
from db.azure_sync import sync_local_from_azure, push_access_requests, push_user_update, remote_access_decision
from config.constants import MACHINE_ID
from utils.startup_check import startup_sequence
from config.constants import STATUS_IN_USE, LCD_LINE_DELAY

logger = logging.getLogger("validator")

def validate_card(csu_id, uid_num, db, lcd, relay, temp=False):
    """Access check for a person. `temp` marks a temporary card: uid_num is then None, so no student UID is
    recorded against the user or their access request."""
    logger.info(f"[VALIDATOR] {'Temp card' if temp else 'Card'} scanned: {csu_id}")
    # Ask the server so dashboard changes apply to this scan; the local cache is only a fallback.
    decision = remote_access_decision(csu_id, MACHINE_ID)
    source = "server"
    if decision is None:
        decision = db.access_decision(csu_id, MACHINE_ID)
        source = "local cache"
    allowed, reason, via = decision
    logger.info(f"[VALIDATOR] Decision for {csu_id} ({source}): allowed={allowed} reason={reason} via={via}")

    user = db.get_user(csu_id)
    if allowed and not user:
        # Approved on the dashboard since the last sync; pull it so the name and UID are known.
        try:
            sync_local_from_azure()
            user = db.get_user(csu_id)
        except Exception as e:
            logger.error(f"[VALIDATOR] Sync for new user failed: {e}")

    if reason in ("unknown_user", "no_permission"):
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

        startup_sequence(lcd, db)
        return None, None

    if not allowed:
        # group_disabled, outside_hours, unknown_machine
        line2 = {"group_disabled": "Account locked", "outside_hours": "Outside hours"}.get(reason, "Contact admin")
        lcd.display("Access Denied", line2, color="red")
        logger.warning(f"[ACCESS] Denied: {csu_id} ({reason})")
        time.sleep(LCD_LINE_DELAY)
        return None, None

    display_name = user["name"] if user and user["name"] else str(csu_id)

    if uid_num is not None and db.ensure_user_uid(csu_id, uid_num):
        logger.info(f"[SYNC] UID updated for {csu_id}, syncing to server")
        push_user_update(csu_id)

    logger.info(f"[ACCESS] Granted to {csu_id} - {display_name}")
    db.mark_user_active(csu_id)
    db.update_machine_status(MACHINE_ID, STATUS_IN_USE)
    db.update_machine_heartbeat(MACHINE_ID)
    relay.turn_on()
    return csu_id, display_name
