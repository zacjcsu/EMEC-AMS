import sqlite3
import os
import logging
from datetime import datetime
from config.constants import LOCAL_DB_PATH
from create_local_db import create_local_db
from config.constants import (
    STATUS_NEUTRAL, STATUS_IN_USE, STATUS_OFFLINE, STATUS_MAINTENANCE
)

logger = logging.getLogger("local_db")


class LocalDB:
    def __init__(self):
        if not os.path.exists(LOCAL_DB_PATH):
            create_local_db()

        self.conn = sqlite3.connect(LOCAL_DB_PATH)
        self.conn.row_factory = sqlite3.Row
        self.cursor = self.conn.cursor()

    def get_machine(self, machine_id):
        self.cursor.execute("SELECT * FROM Machine WHERE machine_id = ?", (machine_id,))
        return self.cursor.fetchone()

    def insert_machine_if_missing(self, machine_id, machine_name, machine_type):
        self.cursor.execute("SELECT * FROM Machine WHERE machine_id = ?", (machine_id,))
        if not self.cursor.fetchone():
            self.cursor.execute("""
                INSERT INTO Machine (machine_id, machine_name, machine_type, machine_status)
                VALUES (?, ?, ?, ?)
            """, (machine_id, machine_name, machine_type, STATUS_NEUTRAL))
            self.conn.commit()

    def update_machine_status(self, machine_id, status):
        if (status != STATUS_MAINTENANCE):
            self.cursor.execute("UPDATE Machine SET machine_status = ? WHERE machine_id = ?", (status, machine_id))
            self.conn.commit()
        else:
            logger.warning(f"{machine_id} is in maintenance mode, status update skipped.")

    def update_machine_ip(self, machine_id, device_ip):
        self.cursor.execute("UPDATE Machine SET device_ip = ? WHERE machine_id = ?", (device_ip, machine_id))
        self.conn.commit()

    def update_machine_device(self, machine_id, device_id):
        self.cursor.execute("UPDATE Machine SET device_id = ? WHERE machine_id = ?", (device_id, machine_id))
        self.conn.commit()

    def update_machine_heartbeat(self, machine_id):
        now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        self.cursor.execute("UPDATE Machine SET last_heartbeat = ? WHERE machine_id = ?", (now, machine_id))
        self.conn.commit()

    def get_setting(self, key, default=None):
        self.cursor.execute("SELECT value FROM System_Settings WHERE setting = ?", (key,))
        row = self.cursor.fetchone()
        return row["value"] if row else default

    def get_open_close_times(self):
        self.cursor.execute(
            "SELECT setting, value FROM System_Settings WHERE setting IN ('lab_open_time', 'lab_close_time')"
        )
        settings = {row['setting']: row['value'] for row in self.cursor.fetchall()}
        return settings.get('lab_open_time'), settings.get('lab_close_time')

    def get_user(self, csu_id):
        self.cursor.execute("SELECT * FROM Users WHERE csu_id = ?", (csu_id,))
        return self.cursor.fetchone()

    def has_permission(self, csu_id, machine_id):
        self.cursor.execute(
            "SELECT 1 FROM Machine_Permissions WHERE csu_id = ? AND machine_id = ?",
            (csu_id, machine_id)
        )
        return self.cursor.fetchone() is not None

    def access_request_exists(self, csu_id, machine_id):
        self.cursor.execute(
            "SELECT 1 FROM Access_Requests WHERE csu_id = ? AND machine_id = ? AND status = 'under review'",
            (csu_id, machine_id)
        )
        return self.cursor.fetchone() is not None

    def insert_access_request(self, csu_id, machine_id, uid_fallback):
        now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        self.cursor.execute("SELECT uid FROM Users WHERE csu_id = ?", (csu_id,))
        user = self.cursor.fetchone()
        uid = user["uid"] if user else uid_fallback

        self.cursor.execute("SELECT machine_type FROM Machine WHERE machine_id = ?", (machine_id,))
        machine = self.cursor.fetchone()
        machine_type = machine["machine_type"] if machine else None

        self.cursor.execute("""
            INSERT INTO Access_Requests (
                uid, csu_id, machine_id, machine_type,
                status, requested_on
            ) VALUES (?, ?, ?, ?, 'under review', ?)
        """, (uid, csu_id, machine_id, machine_type, now))
        self.conn.commit()

    def mark_user_active(self, csu_id):
        now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        self.cursor.execute(
            "UPDATE Users SET is_active = 1, last_used = ? WHERE csu_id = ?", (now, csu_id,)
        )
        self.conn.commit()

    def mark_user_inactive(self, csu_id):
        now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        self.cursor.execute(
            "UPDATE Users SET is_active = 0, last_used = ? WHERE csu_id = ?", (now, csu_id,)
        )
        self.conn.commit()

    def insert_session(self, session_id, csu_id, machine_id):
        now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        self.cursor.execute("SELECT machine_type FROM Machine WHERE machine_id = ?", (machine_id,))
        result = self.cursor.fetchone()
        machine_type = result["machine_type"] if result and result["machine_type"] else "Unknown"

        self.cursor.execute(
            "INSERT INTO Machine_Usage (session_id, csu_id, machine_id, machine_type, start_time) "
            "VALUES (?, ?, ?, ?, ?)",
            (session_id, csu_id, machine_id, machine_type, now)
        )
        self.conn.commit()

    def end_session(self, session_id):
        now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        self.cursor.execute("""
            UPDATE Machine_Usage
            SET end_time = ?,
                duration = ((strftime('%s',?) - strftime('%s', start_time)) / 60)
            WHERE session_id = ?
        """, (now, now, session_id,))
        self.conn.commit()

    def ensure_user_uid(self, csu_id, uid):
        self.cursor.execute("SELECT uid FROM Users WHERE csu_id = ?", (csu_id,))
        result = self.cursor.fetchone()
        if result and (result["uid"] is None or result["uid"].strip() == ""):
            self.cursor.execute("UPDATE Users SET uid = ? WHERE csu_id = ?", (str(uid), csu_id))
            self.conn.commit()
            return True
        return False

    def user_has_level(self, csu_id, level_name):
        self.cursor.execute(
            "SELECT 1 FROM User_Access WHERE csu_id = ? AND level_name = ?",
            (csu_id, level_name)
        )
        return self.cursor.fetchone() is not None

    def close(self):
        self.conn.close()
