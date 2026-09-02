# config/constants.py

from dotenv import load_dotenv
load_dotenv()
import os
import json

# === Device ID (CPU Serial) ===
def get_cpu_serial():
    try:
        with open("/proc/cpuinfo", "r") as f:
            for line in f:
                if line.startswith("Serial"):
                    return line.strip().split(":")[1].strip()
    except:
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
    except:
        return ("UNKNOWN", "Unnamed Machine", "Unknown Type")

MACHINE_ID, MACHINE_NAME, MACHINE_TYPE = load_machine_config()


# === Relay and Card Constants ===
RELAY_PIN = 11
CARD_POLL_INTERVAL = 0.5  # seconds
CARD_GRACE_PERIOD_DEFAULT = 10  # fallback if not in system_settings
LCD_LINE_DELAY = 2  # seconds
LOCAL_DB_PATH = "data/local.db"

# === Azure Environment Variables ===
AZURE_ENV_KEYS = {
    "host": os.getenv("AZURE_HOST"),
    "user": os.getenv("AZURE_USER"),
    "password": os.getenv("AZURE_PASSWORD"),
    "database": os.getenv("AZURE_DATABASE"),
    "ssl_ca": os.getenv("AZURE_SSL_CA")
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
    "azure_error": ["Azure Error", "Check conn."],
    "sync_error": ["Sync failed", "Check conn."]
}



