# create_local_db.py

import sqlite3
import os

DB_PATH = "data/local.db"
os.makedirs("data", exist_ok=True)

schema = """
-- USERS
CREATE TABLE IF NOT EXISTS Users (
    csu_id TEXT PRIMARY KEY,
    uid TEXT,
    name TEXT,
    last_used TEXT,
    is_active INTEGER DEFAULT 0
);

-- USER ACCESS 
CREATE TABLE IF NOT EXISTS User_Access (
    csu_id TEXT,
    level_name TEXT,
    added_at TEXT,
    PRIMARY KEY (csu_id, level_name)
);

-- ACCESS LEVELS
CREATE TABLE IF NOT EXISTS Access_Levels (
    level_name TEXT PRIMARY KEY
);

-- USER GROUPS
CREATE TABLE IF NOT EXISTS User_Groups (
    csu_id TEXT,
    group_name TEXT,
    added_at TEXT,
    PRIMARY KEY (csu_id, group_name)
);

-- MACHINE
CREATE TABLE IF NOT EXISTS Machine (
    machine_id TEXT PRIMARY KEY,
    machine_type TEXT,
    machine_name TEXT,
    machine_status TEXT DEFAULT 'offline',
    device_ip TEXT,
    last_heartbeat TEXT,
    device_id TEXT
);

-- MACHINE PERMISSIONS
CREATE TABLE IF NOT EXISTS Machine_Permissions (
    csu_id TEXT,
    machine_id TEXT,
    machine_type TEXT,
    permission_status TEXT,
    permission_mode TEXT,
    modified_by TEXT,
    modified_at TEXT,
    PRIMARY KEY (csu_id, machine_id)
);

-- ACCESS REQUESTS
CREATE TABLE IF NOT EXISTS Access_Requests (
    request_id INTEGER PRIMARY KEY AUTOINCREMENT,
    uid TEXT,
    csu_id TEXT,
    machine_id TEXT,
    machine_type TEXT,
    requested_on TEXT,
    status TEXT DEFAULT 'under review',
    reviewed_by TEXT,
    reviewed_at TEXT
);

-- MACHINE USAGE
CREATE TABLE IF NOT EXISTS Machine_Usage (
    log_id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT,
    csu_id TEXT,
    machine_id TEXT,
    machine_type TEXT,
    start_time TEXT,
    end_time TEXT,
    duration INTEGER
);

-- SYSTEM SETTINGS
CREATE TABLE IF NOT EXISTS System_Settings (
    setting TEXT PRIMARY KEY,
    value TEXT,
    description TEXT,
    last_updated TEXT
);
"""

def create_local_db():
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()
    cur.executescript(schema)
    conn.commit()
    conn.close()
    print(f"Local DB created at {DB_PATH}")
