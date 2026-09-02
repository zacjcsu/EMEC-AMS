#!/usr/bin/env bash
#
# EMEC Access Management System - Raspberry Pi provisioning script
#
# Usage (recommended, works with interactive prompts):
#   curl -fsSL <URL> -o emec-setup.sh && bash emec-setup.sh
#
# Fully unattended:
#   MACHINE_ID=lathe-001 MACHINE_NAME="Manual Lathe 1" MACHINE_TYPE="Manual Lathe" \
#     bash emec-setup.sh --yes
#
# Safe to re-run. Existing config is kept unless you change it at the prompts.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

APP_USER="${APP_USER:-emec}"
APP_DIR="${APP_DIR:-/home/${APP_USER}/emec-ams}"
VENV_DIR="${APP_DIR}/myvenv"
SERVICE_NAME="emec-ams"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Where the application code comes from: "drive" or "git".
#   drive - downloads a .zip from Google Drive (set SOURCE_DRIVE_ID)
#   git   - clones from GitHub (set SOURCE_REPO / SOURCE_BRANCH)
SOURCE_MODE="${SOURCE_MODE:-drive}"

# Google Drive file ID of emec-ams.zip.
# From a share link like https://drive.google.com/file/d/<THIS_PART>/view
SOURCE_DRIVE_ID="${SOURCE_DRIVE_ID:-1xKYNR2btNIZu5AqLziXFbyG05NyFkOai}"

SOURCE_REPO="${SOURCE_REPO:-https://github.com/Tharunya07/EMEC-AMS.git}"
SOURCE_BRANCH="${SOURCE_BRANCH:-main}"

# Locale / regional settings applied non-interactively (replaces raspi-config).
TIMEZONE="${TIMEZONE:-America/Denver}"
KEYBOARD_LAYOUT="${KEYBOARD_LAYOUT:-us}"
WIFI_COUNTRY="${WIFI_COUNTRY:-US}"

# Azure MySQL connection, written to ${APP_DIR}/.env
# NOTE: these credentials are baked in. Anyone who can read this script can read
# them. Restrict who can reach the hosted copy, and rotate the password if the
# script is ever posted somewhere public.
AZURE_HOST="${AZURE_HOST:-ams-mysql-server.mysql.database.azure.com}"
AZURE_USER="${AZURE_USER:-pi}"
AZURE_PASSWORD="${AZURE_PASSWORD:-Tharunya123}"
AZURE_DATABASE="${AZURE_DATABASE:-emec_access}"
AZURE_SSL_CA="${AZURE_SSL_CA:-/etc/ssl/certs/ca-certificates.crt}"

ASSUME_YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && ASSUME_YES=1

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
    C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
    C_RESET=""; C_BOLD=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

step() { printf '\n%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s[ok]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '    %s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '\n%s[error]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# Prompts read from the terminal, not stdin, so the script still works when it
# is piped into bash.
if [[ -r /dev/tty ]]; then TTY=/dev/tty; else TTY=/dev/stdin; fi

ask() {
    # ask <variable-name> <prompt> <default>
    local __var="$1" __prompt="$2" __default="$3" __reply=""
    if (( ASSUME_YES )); then
        printf -v "$__var" '%s' "$__default"
        info "${__prompt}: ${__default}"
        return
    fi
    read -r -p "    ${__prompt} [${__default}]: " __reply <"$TTY" || true
    printf -v "$__var" '%s' "${__reply:-$__default}"
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# ---------------------------------------------------------------------------
# 0. Preflight
# ---------------------------------------------------------------------------

step "Preflight checks"

[[ "$(id -u)" -eq 0 ]] && die "Run this as the '${APP_USER}' user, not as root. It will call sudo where needed."

if [[ "$(id -un)" != "$APP_USER" ]]; then
    warn "Running as '$(id -un)' but installing for '${APP_USER}'."
    warn "The service runs as '${APP_USER}', so file ownership will be fixed at the end."
fi

id "$APP_USER" >/dev/null 2>&1 || die "User '${APP_USER}' does not exist. Create it first: sudo adduser ${APP_USER}"

command -v sudo >/dev/null || die "sudo is not installed."
command -v systemctl >/dev/null || die "systemd not found. This script targets Raspberry Pi OS."

PI_MODEL="unknown"
if [[ -r /proc/device-tree/model ]]; then
    PI_MODEL="$(tr -d '\0' </proc/device-tree/model)"
fi
info "Device: ${PI_MODEL}"

IS_PI5=0
[[ "$PI_MODEL" == *"Raspberry Pi 5"* ]] && IS_PI5=1
(( IS_PI5 )) && info "Pi 5 detected: will substitute rpi-lgpio for RPi.GPIO."

step "Requesting sudo access up front"
sudo -v || die "sudo authentication failed."
# Keep the sudo timestamp alive for the length of the run.
( while true; do sudo -n true 2>/dev/null || exit; sleep 50; done ) &
SUDO_KEEPALIVE=$!
trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null || true' EXIT
ok "sudo ready"

# ---------------------------------------------------------------------------
# 1. Machine identity
# ---------------------------------------------------------------------------

step "Machine identity (written to config/config.json)"

DEF_ID="lathe-001"; DEF_NAME="Manual Lathe 1"; DEF_TYPE="Manual Lathe"
if [[ -f "${APP_DIR}/config/config.json" ]] && command -v python3 >/dev/null; then
    # Re-run: offer the values already on this Pi as the defaults.
    eval "$(python3 - "${APP_DIR}/config/config.json" <<'PY' 2>/dev/null || true
import json, shlex, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for k, v in (("DEF_ID", "machine_id"), ("DEF_NAME", "machine_name"), ("DEF_TYPE", "machine_type")):
    if d.get(v):
        print(f"{k}={shlex.quote(str(d[v]))}")
PY
)"
    info "Found an existing config on this Pi; its values are the defaults below."
fi

MACHINE_ID="${MACHINE_ID:-}"; MACHINE_NAME="${MACHINE_NAME:-}"; MACHINE_TYPE="${MACHINE_TYPE:-}"
[[ -z "$MACHINE_ID"   ]] && ask MACHINE_ID   "Machine ID"   "$DEF_ID"
[[ -z "$MACHINE_NAME" ]] && ask MACHINE_NAME "Machine name" "$DEF_NAME"
[[ -z "$MACHINE_TYPE" ]] && ask MACHINE_TYPE "Machine type" "$DEF_TYPE"

[[ -n "$MACHINE_ID" ]] || die "Machine ID cannot be empty."
ok "${MACHINE_ID} / ${MACHINE_NAME} / ${MACHINE_TYPE}"

# ---------------------------------------------------------------------------
# 2. Regional settings (the raspi-config steps, done non-interactively)
# ---------------------------------------------------------------------------

step "Regional settings"

if sudo timedatectl set-timezone "$TIMEZONE" 2>/dev/null; then
    ok "Timezone: ${TIMEZONE}"
else
    warn "Could not set timezone to ${TIMEZONE}."
fi

if command -v raspi-config >/dev/null; then
    sudo raspi-config nonint do_configure_keyboard "$KEYBOARD_LAYOUT" >/dev/null 2>&1 \
        && ok "Keyboard layout: ${KEYBOARD_LAYOUT}" \
        || warn "Could not set keyboard layout."
    sudo raspi-config nonint do_wifi_country "$WIFI_COUNTRY" >/dev/null 2>&1 \
        && ok "Wi-Fi country: ${WIFI_COUNTRY}" \
        || warn "Could not set Wi-Fi country (harmless on wired-only units)."
else
    warn "raspi-config not found; skipping keyboard and Wi-Fi country."
fi

# ---------------------------------------------------------------------------
# 3. Hardware interfaces
# ---------------------------------------------------------------------------

step "Enabling SPI (RFID reader) and I2C (LCD)"

REBOOT_NEEDED=0
if command -v raspi-config >/dev/null; then
    # raspi-config nonint uses 0 = enable.
    sudo raspi-config nonint do_spi 0 && ok "SPI enabled" || warn "Could not enable SPI."
    sudo raspi-config nonint do_i2c 0 && ok "I2C enabled" || warn "Could not enable I2C."
else
    CONFIG_TXT=/boot/firmware/config.txt
    [[ -f "$CONFIG_TXT" ]] || CONFIG_TXT=/boot/config.txt
    for param in spi i2c_arm; do
        if ! grep -qE "^dtparam=${param}=on" "$CONFIG_TXT" 2>/dev/null; then
            echo "dtparam=${param}=on" | sudo tee -a "$CONFIG_TXT" >/dev/null
            ok "Added dtparam=${param}=on to ${CONFIG_TXT}"
            REBOOT_NEEDED=1
        fi
    done
fi

[[ -e /dev/spidev0.0 ]] || REBOOT_NEEDED=1
[[ -e /dev/i2c-1 ]]     || REBOOT_NEEDED=1

HW_GROUPS=""
for g in spi i2c gpio dialout; do
    getent group "$g" >/dev/null && HW_GROUPS="${HW_GROUPS:+${HW_GROUPS},}${g}"
done
if [[ -n "$HW_GROUPS" ]]; then
    sudo usermod -aG "$HW_GROUPS" "$APP_USER" \
        && ok "Added ${APP_USER} to: ${HW_GROUPS}" \
        || warn "Could not add ${APP_USER} to hardware groups."
fi

# ---------------------------------------------------------------------------
# 4. System packages
# ---------------------------------------------------------------------------

step "Installing system packages"

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq \
    git curl unzip rsync ca-certificates \
    python3 python3-venv python3-dev python3-pip python3-smbus \
    build-essential i2c-tools >/dev/null
ok "Base packages installed"

# ---------------------------------------------------------------------------
# 5. Fetch the application code
# ---------------------------------------------------------------------------

step "Fetching application code (source: ${SOURCE_MODE})"

sudo mkdir -p "$APP_DIR"
sudo chown "${APP_USER}:${APP_USER}" "$APP_DIR"

STAGE="$(mktemp -d)"
trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null || true; rm -rf "$STAGE"' EXIT

fetch_from_drive() {
    [[ -n "$SOURCE_DRIVE_ID" && "$SOURCE_DRIVE_ID" != "PUT_THE_ZIP_FILE_ID_HERE" ]] \
        || die "SOURCE_DRIVE_ID is not set. Edit the script or pass SOURCE_DRIVE_ID=<id>."

    local zip="${STAGE}/emec-ams.zip"
    info "Downloading zip from Google Drive..."
    curl -fsSL --retry 3 \
        "https://drive.usercontent.google.com/download?id=${SOURCE_DRIVE_ID}&export=download&confirm=t" \
        -o "$zip" || die "Download failed. Check the file ID and that sharing is 'Anyone with the link'."

    # A Drive permission error comes back as an HTML page, not a zip.
    unzip -tq "$zip" >/dev/null 2>&1 \
        || die "Downloaded file is not a valid zip (Drive probably returned an error page). Set sharing to 'Anyone with the link'."

    unzip -q -o "$zip" -d "${STAGE}/unpacked"
    ok "Zip extracted"
}

fetch_from_git() {
    info "Cloning ${SOURCE_REPO} (branch ${SOURCE_BRANCH})..."
    git clone --depth 1 --branch "$SOURCE_BRANCH" "$SOURCE_REPO" "${STAGE}/unpacked/repo" \
        || die "Clone failed."
    ok "Repository cloned"
}

case "$SOURCE_MODE" in
    drive) fetch_from_drive ;;
    git)   fetch_from_git ;;
    *)     die "SOURCE_MODE must be 'drive' or 'git', got '${SOURCE_MODE}'." ;;
esac

# Locate main.py wherever it landed inside the archive or clone.
MAIN_PY="$(find "${STAGE}/unpacked" -name main.py -not -path '*/.git/*' -print -quit)"
[[ -n "$MAIN_PY" ]] || die "Could not find main.py in the downloaded code."
SRC_ROOT="$(dirname "$MAIN_PY")"
info "Source root: ${SRC_ROOT}"

step "Installing code into ${APP_DIR}"

# Preserve anything that is per-Pi state: the venv, logs, local database, and
# the config files this script writes below.
rsync -a --delete \
    --exclude 'myvenv/' \
    --exclude 'logs/' \
    --exclude 'data/' \
    --exclude '.env' \
    --exclude '.gitignore' \
    --exclude 'config/config.json' \
    --exclude '.git/' \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    "${SRC_ROOT}/" "${APP_DIR}/" \
    || die "Failed to copy the code into ${APP_DIR}."
ok "Code in place"

mkdir -p "${APP_DIR}/logs" "${APP_DIR}/data" "${APP_DIR}/config"
touch "${APP_DIR}/logs/errors.log" "${APP_DIR}/logs/sync.log"

# ---------------------------------------------------------------------------
# 6. Config files
# ---------------------------------------------------------------------------

step "Writing configuration"

umask 077
cat >"${APP_DIR}/.env" <<EOF
AZURE_HOST=${AZURE_HOST}
AZURE_USER=${AZURE_USER}
AZURE_PASSWORD=${AZURE_PASSWORD}
AZURE_DATABASE=${AZURE_DATABASE}
AZURE_SSL_CA=${AZURE_SSL_CA}
EOF
umask 022
chmod 600 "${APP_DIR}/.env"
ok ".env written (mode 600)"

cat >"${APP_DIR}/config/config.json" <<EOF
{
  "machine_id": "$(json_escape "$MACHINE_ID")",
  "machine_name": "$(json_escape "$MACHINE_NAME")",
  "machine_type": "$(json_escape "$MACHINE_TYPE")"
}
EOF
ok "config/config.json written"

# Keep secrets and per-Pi state out of git if this is a clone.
if [[ ! -f "${APP_DIR}/.gitignore" ]]; then
    cat >"${APP_DIR}/.gitignore" <<'EOF'
.env
myvenv/
data/
logs/
__pycache__/
*.pyc
config/config.json
EOF
fi

# ---------------------------------------------------------------------------
# 7. Python environment
# ---------------------------------------------------------------------------

step "Setting up the virtual environment"

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    python3 -m venv "$VENV_DIR"
    ok "Created ${VENV_DIR}"
else
    ok "Reusing existing venv"
fi

"${VENV_DIR}/bin/python" -m pip install --upgrade pip setuptools wheel -q

if [[ -f "${APP_DIR}/requirements.txt" ]]; then
    "${VENV_DIR}/bin/pip" install -q -r "${APP_DIR}/requirements.txt" \
        || die "pip install failed. Scroll up for the failing package."
    ok "Requirements installed"
else
    warn "No requirements.txt found; skipping."
fi

if (( IS_PI5 )); then
    # RPi.GPIO installs on a Pi 5 but fails at runtime. rpi-lgpio is a drop-in
    # replacement that provides the same 'RPi.GPIO' module name.
    "${VENV_DIR}/bin/pip" uninstall -y -q RPi.GPIO rpi-gpio 2>/dev/null || true
    "${VENV_DIR}/bin/pip" install -q rpi-lgpio \
        && ok "Installed rpi-lgpio (Pi 5 replacement for RPi.GPIO)" \
        || warn "Could not install rpi-lgpio; GPIO will fail on this Pi 5."
fi

# spidev is required by mfrc522 and is easy to miss.
"${VENV_DIR}/bin/python" -c 'import spidev' 2>/dev/null \
    || "${VENV_DIR}/bin/pip" install -q spidev || true

chmod +x "${APP_DIR}/main.py" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 7b. Known compatibility fixes
# ---------------------------------------------------------------------------

step "Compatibility fixes"

# lcd/RGB1602.py does `from smbus import SMBus`, but requirements.txt ships
# smbus2, which provides the module name `smbus2`, not `smbus`. That import
# only resolves if the system-wide python3-smbus is visible, which it is on the
# Desktop image and is not inside a clean venv. smbus2 is API-compatible for
# the single call this file makes (write_byte_data), so rewrite the import.
RGB_FILE="${APP_DIR}/lcd/RGB1602.py"
if [[ -f "$RGB_FILE" ]] && grep -q '^from smbus import SMBus' "$RGB_FILE"; then
    if ! "${VENV_DIR}/bin/python" -c 'import smbus' 2>/dev/null; then
        sed -i 's/^from smbus import SMBus/from smbus2 import SMBus/' "$RGB_FILE"
        warn "Patched lcd/RGB1602.py: 'from smbus import SMBus' -> 'from smbus2 import SMBus'."
        warn "Fix this upstream in the repo so the patch is not needed on the next Pi."
    fi
fi

step "Verifying the install"

VERIFY_OUT="$(cd "$APP_DIR" && "${VENV_DIR}/bin/python" - <<'PYCHECK'
import importlib, sys
missing = []
hardware = []
for mod in ("dotenv", "dateutil", "pymysql", "mfrc522", "RPi.GPIO", "spidev",
            "config.constants", "db.local_db", "rfid.reader", "lcd.RGB1602"):
    try:
        importlib.import_module(mod)
    except ModuleNotFoundError as e:
        missing.append(f"{mod}: {e}")
    except (OSError, RuntimeError) as e:
        # bus/GPIO not available yet (pre-reboot, or not on a Pi). Not a packaging problem.
        hardware.append(f"{mod}: {e}")
    except Exception as e:
        hardware.append(f"{mod}: {type(e).__name__}: {e}")
print("MISSING:" + "|".join(missing))
print("HARDWARE:" + "|".join(hardware))
PYCHECK
)" || true

MISSING_MODS="$(printf '%s\n' "$VERIFY_OUT" | sed -n 's/^MISSING://p')"
HARDWARE_MODS="$(printf '%s\n' "$VERIFY_OUT" | sed -n 's/^HARDWARE://p')"

if [[ -n "$MISSING_MODS" ]]; then
    warn "Missing Python modules (these will stop the service):"
    printf '%s\n' "$MISSING_MODS" | tr '|' '\n' | sed 's/^/      /'
else
    ok "All Python imports resolve"
fi
if [[ -n "$HARDWARE_MODS" ]]; then
    info "Hardware not responding yet (normal before the SPI/I2C reboot):"
    printf '%s\n' "$HARDWARE_MODS" | tr '|' '\n' | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
# 8. systemd service
# ---------------------------------------------------------------------------

step "Installing the systemd service"

sudo tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=EMEC Access Management System
After=network-online.target
Wants=network-online.target

[Service]
User=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=${VENV_DIR}/bin/python ${APP_DIR}/main.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

StandardOutput=append:${APP_DIR}/logs/errors.log
StandardError=append:${APP_DIR}/logs/errors.log

[Install]
WantedBy=multi-user.target
EOF
ok "${SERVICE_FILE} written"

sudo chown -R "${APP_USER}:${APP_USER}" "$APP_DIR"

sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}.service" >/dev/null 2>&1
sudo systemctl restart "${SERVICE_NAME}.service"
ok "Service enabled and started"

sleep 3
step "Service status"
sudo systemctl status "${SERVICE_NAME}.service" --no-pager --lines=15 || true

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

cat <<EOF

${C_GREEN}${C_BOLD}Setup complete.${C_RESET}

  Machine     ${MACHINE_ID} (${MACHINE_NAME})
  Install dir ${APP_DIR}
  Service     ${SERVICE_NAME}.service

  Live logs      journalctl -u ${SERVICE_NAME}.service -f
  App logs       tail -f ${APP_DIR}/logs/errors.log ${APP_DIR}/logs/sync.log
  Restart        sudo systemctl restart ${SERVICE_NAME}.service
  I2C check      i2cdetect -y 1
  SPI check      ls -l /dev/spidev*
EOF

if (( REBOOT_NEEDED )); then
    printf '\n%s[action needed]%s SPI/I2C were just enabled. Reboot before the reader and LCD will work:\n    sudo reboot\n' \
        "$C_YELLOW" "$C_RESET"
fi
