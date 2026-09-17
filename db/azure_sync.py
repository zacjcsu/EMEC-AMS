import pymysql
import sqlite3
import logging
import os
from config.constants import AZURE_ENV_KEYS, LOCAL_DB_PATH

logger = logging.getLogger("azure_sync")

def get_azure_connection():
    return pymysql.connect(
        host=AZURE_ENV_KEYS["host"],
        user=AZURE_ENV_KEYS["user"],
        password=AZURE_ENV_KEYS["password"],
        db=AZURE_ENV_KEYS["database"],
        ssl={"ca": AZURE_ENV_KEYS["ssl_ca"]},
        cursorclass=pymysql.cursors.DictCursor
    )

def sync_local_from_azure():
    conn_local = sqlite3.connect(LOCAL_DB_PATH)
    cursor_local = conn_local.cursor()

    conn_azure = get_azure_connection()
    cursor_azure = conn_azure.cursor()

    tables = ['Users', 'User_Access','Access_Levels', 'Access_Requests', 'Machine_Permissions', 'System_Settings', 'Machine']

    for table in tables:
        try:
            cursor_azure.execute(f"SELECT * FROM {table}")
            rows = cursor_azure.fetchall()

            cursor_local.execute(f"DELETE FROM {table}")
            if rows:
                keys = rows[0].keys()
                placeholders = ", ".join(["?"] * len(keys))
                query = f"INSERT INTO {table} ({', '.join(keys)}) VALUES ({placeholders})"
                for row in rows:
                    cursor_local.execute(query, tuple(row.values()))
            logger.info(f"[SYNC] Pulled {len(rows)} rows from Azure -> {table}")
        except Exception as e:
            logger.error(f"[SYNC] ERROR syncing table {table}: {e}")

    conn_local.commit()
    conn_local.close()
    conn_azure.close()

def sync_session_to_azure(session_id):
    try:
        conn_local = sqlite3.connect(LOCAL_DB_PATH)
        cur = conn_local.cursor()
        cur.execute("SELECT session_id, csu_id, machine_id, machine_type, start_time, end_time, duration FROM Machine_Usage WHERE session_id = ?", (session_id,))
        row = cur.fetchone()
        if not row:
            return

        conn_azure = get_azure_connection()
        cursor_az = conn_azure.cursor()
        cursor_az.execute(
            "REPLACE INTO Machine_Usage (session_id, csu_id, machine_id, machine_type, start_time, end_time, duration) VALUES (%s, %s, %s, %s, %s, %s, %s)",
            row
        )
        conn_azure.commit()
        conn_azure.close()

        cur.execute("DELETE FROM Machine_Usage WHERE session_id = ?", (session_id,))
        conn_local.commit()
        conn_local.close()
        logger.info(f"[SYNC] Session {session_id} synced and removed locally.")
    except Exception as e:
        logger.error(f"[SYNC] Session sync failed: {e}")

def push_machine_status(db, machine_id):
    machine = db.get_machine(machine_id)
    if not machine:
        logger.warning(f"[SYNC] Machine {machine_id} not found locally.")
        return

    try:
        conn = get_azure_connection()
        cur = conn.cursor()

        cur.execute(
            """
            INSERT INTO Machine (machine_id, machine_name, machine_type, device_ip, machine_status, last_heartbeat, device_id)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
            ON DUPLICATE KEY UPDATE
                machine_name=VALUES(machine_name),
                machine_type=VALUES(machine_type),
                device_ip=VALUES(device_ip),
                machine_status=VALUES(machine_status),
                last_heartbeat=VALUES(last_heartbeat),
                device_id=VALUES(device_id)
            """,
            (
                machine["machine_id"],
                machine["machine_name"],
                machine["machine_type"],
                machine["device_ip"] if "device_ip" in machine.keys() else None,
                machine["machine_status"],
                machine["last_heartbeat"],
                machine["device_id"] if "device_id" in machine.keys() else None
            )
        )

        conn.commit()
        conn.close()
        logger.info(f"[SYNC] Machine status pushed for {machine_id}")
    except Exception as e:
        logger.error(f"[SYNC] Machine status push failed: {e}")

def push_user_status(db, csu_id):
    user = db.get_user(csu_id)
    if not user:
        logger.warning(f"[SYNC] User {csu_id} not found locally.")
        return

    try:
        conn = get_azure_connection()
        cur = conn.cursor()
        cur.execute(
            "UPDATE Users SET is_active=%s, last_used=%s WHERE csu_id=%s",
            (user["is_active"], user["last_used"], csu_id)
        )
        conn.commit()
        conn.close()
        logger.info(f"[SYNC] User status pushed for {csu_id}")
    except Exception as e:
        logger.error(f"[SYNC] User status push failed: {e}")

def push_user_update(csu_id):
    try:
        conn_local = sqlite3.connect(LOCAL_DB_PATH)
        conn_local.row_factory = sqlite3.Row
        cur = conn_local.cursor()
        cur.execute("SELECT csu_id, uid, name, last_used, is_active FROM Users WHERE csu_id = ?", (csu_id,))
        row = cur.fetchone()
        conn_local.close()

        if not row:
            logger.warning(f"[SYNC] No local user found with CSU ID {csu_id}")
            return

        conn = get_azure_connection()
        cur = conn.cursor()
        cur.execute("""
            UPDATE Users SET uid = %s, name = %s, last_used = %s, is_active = %s
            WHERE csu_id = %s
        """, (
            row["uid"],
            row["name"],
            row["last_used"],
            row["is_active"],
            row["csu_id"]
        ))
        conn.commit()
        conn.close()
        logger.info(f"[SYNC] UID and info pushed for {csu_id}")
    except Exception as e:
        logger.error(f"[SYNC] Failed to push user update for {csu_id}: {e}")

def push_access_requests():
    try:
        conn_local = sqlite3.connect(LOCAL_DB_PATH)
        cur = conn_local.cursor()
        cur.execute("SELECT request_id, uid, csu_id, machine_id, machine_type, requested_on, status, reviewed_by, reviewed_at FROM Access_Requests WHERE status = 'under review'")
        requests = cur.fetchall()
        if not requests:
            return

        conn_azure = get_azure_connection()
        cur_az = conn_azure.cursor()

        for row in requests:
            cur_az.execute("""
                INSERT INTO Access_Requests (request_id, uid, csu_id, machine_id, machine_type, requested_on, status, reviewed_by, reviewed_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                ON DUPLICATE KEY UPDATE
                uid=VALUES(uid),
                machine_id=VALUES(machine_id),
                machine_type=VALUES(machine_type),
                requested_on=VALUES(requested_on),
                status=VALUES(status),
                reviewed_by=VALUES(reviewed_by),
                reviewed_at=VALUES(reviewed_at)
            """, row)

        conn_azure.commit()
        conn_azure.close()
        logger.info(f"[SYNC] Access requests synced to Azure")
    except Exception as e:
        logger.error(f"[SYNC] Access request sync failed: {e}")
