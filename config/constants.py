from dotenv import load_dotenv
load_dotenv()
import os
import json
import logging

logger = logging.getLogger("constants")

# === Device ID (CPU Serial) ===
def get_cpu_serial():
    try:
        with open("/proc/cpuinfo", "r") as f:
            for line in f:
                if line.startswith("Serial"):
                    return line.strip().split(":")[1].strip()
    except Exception as e:
        logger.warning(f"Could not read CPU serial from /proc/cpuinfo: {e}")
        return "0000000000000000"

DEVICE_ID = get_cpu_serial()

# === Load Config from JSON ===
def load_machine_config():
    try:
        with open("config/config.json", "r") as f:
            data = json.load(f)
            return (
                data.get("machine_id", "UNKNOWN"),
                data.get("machine_name", "Unnamed Machine"),
                data.get("machine_type", "Unknown Type")
            )
    except Exception as e:
        logger.warning(f"Could not load config/config.json: {e}")
        return ("UNKNOWN", "Unnamed Machine", "Unknown Type")

MACHINE_ID, MACHINE_NAME, MACHINE_TYPE = load_machine_config()
MACHINE_ID = MACHINE_ID.casefold()


# === Relay and Card Constants ===
RELAY_PIN = 11
LED_READER_PIN = 16       # GPIO23, D1
LED_HEARTBEAT_PIN = 18    # GPIO24, D2
HEARTBEAT_INTERVAL = 0.5  # toggle every 0.5s = 1 Hz blink
READER_BLINK_DURATION = 0.1
CARD_POLL_INTERVAL = 0.5  # seconds
CARD_GRACE_PERIOD_DEFAULT = 10  # fallback if not in system_settings
LCD_LINE_DELAY = 2  # seconds
IDLE_SCAN_SCREEN_SECONDS = 8       # idle: how long "Scan CSU ID" shows...
IDLE_LAST_USED_SCREEN_SECONDS = 4  # ...before "Last Used" shows this long
LOCAL_DB_PATH = "data/local.db"

# === Database (PostgreSQL on the dashboard VM) ===
DB_ENV = {
    "host": os.getenv("DB_HOST"),
    "port": int(os.getenv("DB_PORT", "5432")),
    "user": os.getenv("DB_USER"),
    "password": os.getenv("DB_PASS"),
    "database": os.getenv("DB_NAME", "emec_access"),
    "sslmode": os.getenv("DB_SSLMODE", "prefer"),
}

# === Required Settings from system_settings table ===
REQUIRED_SYSTEM_SETTINGS = [
    "grace_period_seconds"
]

# === Machine Status Enum ===
STATUS_MAINTENANCE = "maintenance"
STATUS_OFFLINE = "offline"
STATUS_NEUTRAL = "neutral"
STATUS_IN_USE = "in use"

# === LCD Messages ===
LCD_MESSAGES = {
    "start": ["All Clear.", "Welcome to EMEC!"],
    "startup_next": ["Scan CSU ID", "to start"],
    "maintenance": [f"{MACHINE_NAME}", "Out of order"],
    "internet_error": ["No Internet", "Connection"],
    "db_error": ["Server Error", "Check conn."],
    "sync_error": ["Sync failed", "Check conn."]
}



