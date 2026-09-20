"""Sync between the local SQLite cache and the dashboard's PostgreSQL database.

(The module keeps its old name; the Azure/MySQL backend it was written for is gone.)
All timestamps written to the server are naive UTC strings, as the server stores them.
"""
import sqlite3
import logging
import psycopg
from psycopg.rows import dict_row
from config.constants import DB_ENV, LOCAL_DB_PATH, MACHINE_ID
from utils.timeutil import utc_now_str

logger = logging.getLogger("azure_sync")


def get_azure_connection(timeout=10):
    return psycopg.connect(
        host=DB_ENV["host"],
        port=DB_ENV["port"],
        user=DB_ENV["user"],
        password=DB_ENV["password"],
        dbname=DB_ENV["database"],
        sslmode=DB_ENV["sslmode"],
        connect_timeout=timeout,
        row_factory=dict_row,
    )


# Local table -> SELECT run on the server. Aliases must match the local column names
# (create_local_db.py). Timestamps, times and arrays are cast to text, booleans to int, because
# SQLite stores neither natively.
PULL_QUERIES = {
    "Users": (
        "SELECT csu_id, uid, name, last_used::text AS last_used, is_active::int AS is_active FROM users",
        (),
    ),
    "Groups": (
        "SELECT group_name, enabled::int AS enabled FROM groups",
        (),
    ),
    "User_Groups": (
        "SELECT csu_id, group_name FROM user_groups",
        (),
    ),
    "User_Access": (
        "SELECT csu_id, level_name FROM user_access",
        (),
    ),
    "Access_Levels": (
        "SELECT level_name, enabled::int AS enabled FROM access_levels",
        (),
    ),
    "Level_Windows": (
        "SELECT window_id, level_name, array_to_string(days, ',') AS days, "
        "to_char(start_time, 'HH24:MI:SS') AS start_time, to_char(end_time, 'HH24:MI:SS') AS end_time "
        "FROM level_windows",
        (),
    ),
    "Category_Permissions": (
        "SELECT csu_id, machine_type FROM category_permissions",
        (),
    ),
    "Access_Requests": (
        "SELECT request_id, uid, csu_id, machine_id, machine_type, requested_on::text AS requested_on, "
        "status, reviewed_by, reviewed_at::text AS reviewed_at "
        "FROM access_requests WHERE status = 'under review' AND machine_id = %s",
        (MACHINE_ID,),
    ),
    "System_Settings": (
        "SELECT setting, value, description, last_updated::text AS last_updated FROM system_settings",
        (),
    ),
    "Machine": (
        "SELECT machine_id, machine_type, machine_name, machine_status, device_ip, "
        "last_heartbeat::text AS last_heartbeat, device_id FROM machine",
        (),
    ),
}


def sync_local_from_azure():
    """Replace the local cache tables with the server's. All or nothing: raises on any failure so
    the caller never runs on a half-updated permission set."""
    pulled = {}
    conn_pg = get_azure_connection()
    try:
        # One snapshot, so the tables are consistent with each other.
        conn_pg.isolation_level = psycopg.IsolationLevel.REPEATABLE_READ
        with conn_pg.cursor() as cur:
            for table, (query, params) in PULL_QUERIES.items():
                cur.execute(query, params)
                pulled[table] = cur.fetchall()
        conn_pg.rollback()
    finally:
        conn_pg.close()

    conn_local = sqlite3.connect(LOCAL_DB_PATH)
    try:
        with conn_local:  # one transaction: commit on success, roll back on error
            for table, rows in pulled.items():
                conn_local.execute(f"DELETE FROM {table}")
                if rows:
                    keys = list(rows[0].keys())
                    placeholders = ", ".join(["?"] * len(keys))
                    conn_local.executemany(
                        f"INSERT INTO {table} ({', '.join(keys)}) VALUES ({placeholders})",
                        [tuple(r[k] for k in keys) for r in rows],
                    )
                logger.info(f"[SYNC] Pulled {len(rows)} rows from server -> {table}")
    finally:
        conn_local.close()


def remote_access_decision(csu_id, machine_id):
    """(allowed, reason, via) straight from the server's access_decision_machine(), so a change made
    on the dashboard applies to the very next scan. Returns None if the server can't be reached;
    the caller then falls back to the local cache."""
    try:
        with get_azure_connection(timeout=3) as conn:
            row = conn.execute(
                "SELECT allowed, reason, via FROM access_decision_machine(%s, %s)",
                (str(csu_id), machine_id),
            ).fetchone()
        return row["allowed"], row["reason"], row["via"]
    except Exception as e:
        logger.warning(f"[SYNC] Live access check failed, using local cache: {e}")
        return None


def sync_session_to_azure(session_id):
    try:
        conn_local = sqlite3.connect(LOCAL_DB_PATH)
        cur = conn_local.cursor()
        cur.execute("SELECT session_id, csu_id, machine_id, machine_type, start_time, end_time, duration FROM Machine_Usage WHERE session_id = ?", (session_id,))
        row = cur.fetchone()
        if not row:
            conn_local.close()
            return
        session_id, csu_id, machine_id, machine_type, start_time, end_time, duration = row

        with get_azure_connection() as conn:
            with conn.cursor() as cur_pg:
                # Upsert without depending on which unique key the table has.
                cur_pg.execute(
                    "UPDATE machine_usage SET csu_id = %s, machine_id = %s, machine_type = %s, "
                    "start_time = %s, end_time = %s, duration = %s WHERE session_id = %s",
                    (csu_id, machine_id, machine_type, start_time, end_time, duration, session_id),
                )
                if cur_pg.rowcount == 0:
                    cur_pg.execute(
                        "INSERT INTO machine_usage (session_id, csu_id, machine_id, machine_type, start_time, end_time, duration) "
                        "VALUES (%s, %s, %s, %s, %s, %s, %s)",
                        (session_id, csu_id, machine_id, machine_type, start_time, end_time, duration),
                    )

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
        device_ip = machine["device_ip"]
        device_id = machine["device_id"]
        with get_azure_connection() as conn:
            with conn.cursor() as cur:
                # The dashboard owns name and category, so an existing row only gets status fields.
                cur.execute(
                    "UPDATE machine SET machine_status = %s, last_heartbeat = %s, device_ip = %s, device_id = %s "
                    "WHERE machine_id = %s",
                    (machine["machine_status"], machine["last_heartbeat"], device_ip, device_id, machine_id),
                )
                if cur.rowcount == 0:
                    # First run of a new Pi. machine_type must already exist as a category on the dashboard.
                    cur.execute(
                        "INSERT INTO machine (machine_id, machine_name, machine_type, device_ip, machine_status, last_heartbeat, device_id) "
                        "VALUES (%s, %s, %s, %s, %s, %s, %s)",
                        (machine["machine_id"], machine["machine_name"], machine["machine_type"],
                         device_ip, machine["machine_status"], machine["last_heartbeat"], device_id),
                    )
        logger.info(f"[SYNC] Machine status pushed for {machine_id}")
    except Exception as e:
        logger.error(f"[SYNC] Machine status push failed: {e}")


def push_user_status(db, csu_id):
    user = db.get_user(csu_id)
    if not user:
        logger.warning(f"[SYNC] User {csu_id} not found locally.")
        return

    try:
        with get_azure_connection() as conn:
            conn.execute(
                "UPDATE users SET is_active = %s, last_used = %s WHERE csu_id = %s",
                (bool(user["is_active"]), user["last_used"], str(csu_id)),
            )
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

        with get_azure_connection() as conn:
            conn.execute(
                "UPDATE users SET uid = %s, name = %s, last_used = %s, is_active = %s WHERE csu_id = %s",
                (row["uid"], row["name"], row["last_used"], bool(row["is_active"]), str(row["csu_id"])),
            )
        logger.info(f"[SYNC] UID and info pushed for {csu_id}")
    except Exception as e:
        logger.error(f"[SYNC] Failed to push user update for {csu_id}: {e}")


def push_access_requests():
    """Send this machine's locally raised requests to the server. The server assigns request_id
    (local ids would collide across Pis), and a request already under review is not duplicated."""
    try:
        conn_local = sqlite3.connect(LOCAL_DB_PATH)
        cur = conn_local.cursor()
        cur.execute(
            "SELECT uid, csu_id, machine_id, machine_type, requested_on FROM Access_Requests "
            "WHERE status = 'under review' AND machine_id = ?", (MACHINE_ID,))
        requests = cur.fetchall()
        conn_local.close()
        if not requests:
            return

        with get_azure_connection() as conn:
            with conn.cursor() as cur_pg:
                for uid, csu_id, machine_id, machine_type, requested_on in requests:
                    cur_pg.execute(
                        "INSERT INTO access_requests (uid, csu_id, machine_id, machine_type, requested_on, status) "
                        "SELECT %(uid)s::varchar, %(csu)s::varchar, %(mid)s::varchar, %(mt)s::varchar, %(ts)s::timestamp, 'under review' "
                        "WHERE NOT EXISTS (SELECT 1 FROM access_requests WHERE csu_id = %(csu)s::varchar "
                        "AND machine_id = %(mid)s::varchar AND status = 'under review')",
                        {"uid": uid, "csu": csu_id, "mid": machine_id, "mt": machine_type, "ts": requested_on},
                    )
        logger.info("[SYNC] Access requests synced to server")
    except Exception as e:
        logger.error(f"[SYNC] Access request sync failed: {e}")
