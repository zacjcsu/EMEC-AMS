#!/usr/bin/env bash
#
# EMEC Access Management System - Raspberry Pi provisioning script
#
# Usage (recommended, works with interactive prompts):
#   curl -fsSL https://raw.githubusercontent.com/zacjcsu/EMEC-AMS/main/emecamssetup.sh | bash
#
# Fully unattended:
#   curl -fsSL https://raw.githubusercontent.com/zacjcsu/EMEC-AMS/main/emecamssetup.sh \
#     | MACHINE_ID=lathe-001 MACHINE_NAME="Manual Lathe 1" MACHINE_TYPE="Manual Lathe" \
#       AZURE_HOST='...' AZURE_USER='...' AZURE_DATABASE='...' AZURE_PASSWORD='...' \
#       bash -s -- --yes
#
# Safe to re-run: re-running is also how you update a Pi to the latest commit.
# Existing config, venv, logs and local DB are preserved.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

APP_USER="${APP_USER:-emec}"
APP_DIR="${APP_DIR:-/home/${APP_USER}/emec-ams}"
VENV_DIR="${APP_DIR}/.venv"
SERVICE_NAME="emec-ams"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Where the application code comes from: "git" or "drive".
#   git   - clones from GitHub (set SOURCE_REPO / SOURCE_BRANCH). Default.
#   drive - downloads a .zip from Google Drive (set SOURCE_DRIVE_ID). Fallback.
SOURCE_MODE="${SOURCE_MODE:-git}"

# Google Drive file ID of emec-ams.zip. Only used when SOURCE_MODE=drive.
# Left blank on purpose: that zip contains a .env, so publishing its id here
# would publish a pointer to the credentials. Pass SOURCE_DRIVE_ID=<id> if you
# ever need the Drive fallback.
SOURCE_DRIVE_ID="${SOURCE_DRIVE_ID:-}"

SOURCE_REPO="${SOURCE_REPO:-https://github.com/zacjcsu/EMEC-AMS.git}"
SOURCE_BRANCH="${SOURCE_BRANCH:-main}"

# Locale / regional settings applied non-interactively (replaces raspi-config).
TIMEZONE="${TIMEZONE:-America/Denver}"
KEYBOARD_LAYOUT="${KEYBOARD_LAYOUT:-us}"
WIFI_COUNTRY="${WIFI_COUNTRY:-US}"

# Azure MySQL connection, written to ${APP_DIR}/.env at mode 600.
# This file is public, so it holds no host, user, database name or password.
# All of those are prompted for at run time, or passed as environment variables
# for unattended runs. Only the CA path, a standard OS location rather than a
# credential, keeps a default.
DEF_AZURE_SSL_CA="/etc/ssl/certs/ca-certificates.crt"

AZURE_HOST="${AZURE_HOST:-}"
AZURE_USER="${AZURE_USER:-}"
AZURE_PASSWORD="${AZURE_PASSWORD:-}"
AZURE_DATABASE="${AZURE_DATABASE:-}"
AZURE_SSL_CA="${AZURE_SSL_CA:-}"

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

# Prompts read from the controlling terminal, not stdin, so the script still
# works when it is piped into bash. /dev/tty can exist but be unopenable (no
# controlling terminal), so test that it actually opens rather than trusting -r.
TTY=""
if [[ -e /dev/tty ]] && ( : </dev/tty ) 2>/dev/null; then
    TTY=/dev/tty
elif [[ -t 0 ]]; then
    TTY=/dev/stdin
fi
CAN_PROMPT=0
[[ -n "$TTY" ]] && CAN_PROMPT=1

no_prompt_die() {
    die "Cannot prompt for '$1': no terminal available.
      Run from an interactive shell, or re-run non-interactively with --yes and
      supply the values as environment variables, e.g.
        MACHINE_ID=lathe-001 MACHINE_NAME='Manual Lathe 1' \\
        MACHINE_TYPE='Manual Lathe' AZURE_PASSWORD='...' bash -s -- --yes"
}

ask() {
    # ask <variable-name> <prompt> <default>
    local __var="$1" __prompt="$2" __default="$3" __reply=""
    if (( ASSUME_YES )); then
        printf -v "$__var" '%s' "$__default"
        info "${__prompt}: ${__default}"
        return
    fi
    (( CAN_PROMPT )) || no_prompt_die "$__prompt"
    read -r -p "    ${__prompt} [${__default}]: " __reply <"$TTY" || true
    printf -v "$__var" '%s' "${__reply:-$__default}"
}

ask_required() {
    # ask_required <variable-name> <prompt>   (no default, must not be empty)
    local __var="$1" __prompt="$2" __reply="" __try=0
    if (( ASSUME_YES )); then
        die "${__prompt} is required. With --yes, pass it as an environment variable: ${__var}=..."
    fi
    (( CAN_PROMPT )) || no_prompt_die "$__prompt"
    while (( __try < 3 )); do
        read -r -p "    ${__prompt}: " __reply <"$TTY" || true
        if [[ -n "$__reply" ]]; then
            printf -v "$__var" '%s' "$__reply"
            return
        fi
        warn "Cannot be empty."
        __try=$(( __try + 1 ))
    done
    die "Too many failed attempts."
}

ask_secret() {
    # ask_secret <variable-name> <prompt>   (no echo, asks twice to catch typos)
    local __var="$1" __prompt="$2" __a="" __b="" __try=0
    if (( ASSUME_YES )); then
        die "${__prompt} is required. With --yes, pass it as an environment variable: ${__var}=..."
    fi
    (( CAN_PROMPT )) || no_prompt_die "$__prompt"
    while (( __try < 3 )); do
        read -rs -p "    ${__prompt}: " __a <"$TTY" || true; printf '\n'
        read -rs -p "    ${__prompt} (again): " __b <"$TTY" || true; printf '\n'
        if [[ -z "$__a" ]]; then
            warn "Cannot be empty."
        elif [[ "$__a" != "$__b" ]]; then
            warn "Entries did not match."
        else
            printf -v "$__var" '%s' "$__a"
            return
        fi
        __try=$(( __try + 1 ))
    done
    die "Too many failed attempts."
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
if ! sudo -n true 2>/dev/null; then
    (( CAN_PROMPT )) || die "sudo needs a password but there is no terminal to ask on. Run from an interactive shell, or configure passwordless sudo for ${APP_USER}."
fi
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
# 1b. Azure credentials
# ---------------------------------------------------------------------------

step "Azure database credentials (written to .env)"

ENV_FILE="${APP_DIR}/.env"
KEEP_ENV=0

if [[ -f "$ENV_FILE" ]] && [[ -z "$AZURE_PASSWORD" ]]; then
    KEEP_ENV=1
    ok "Existing .env found; keeping it."
    info "To replace it, re-run with AZURE_PASSWORD=... or delete ${ENV_FILE} first."
else
    [[ -z "$AZURE_HOST"     ]] && ask_required AZURE_HOST     "Azure MySQL host"
    [[ -z "$AZURE_USER"     ]] && ask_required AZURE_USER     "Azure MySQL user"
    [[ -z "$AZURE_DATABASE" ]] && ask_required AZURE_DATABASE "Azure database"
    [[ -z "$AZURE_SSL_CA"   ]] && ask AZURE_SSL_CA "SSL CA bundle path" "$DEF_AZURE_SSL_CA"
    [[ -z "$AZURE_PASSWORD" ]] && ask_secret AZURE_PASSWORD "Azure MySQL password"
    ok "Credentials collected for ${AZURE_USER}@${AZURE_HOST}"
fi

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
    --exclude '.venv/' \
    --exclude 'logs/' \
    --exclude 'data/' \
    --exclude '.env' \
    --exclude '.gitignore' \
    --exclude 'config/config.json' \
    --exclude '.git/' \
    --exclude 'hardware/' \
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

if (( KEEP_ENV )); then
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    ok ".env left untouched (mode 600)"
else
    umask 077
    cat >"$ENV_FILE" <<EOF
AZURE_HOST=${AZURE_HOST}
AZURE_USER=${AZURE_USER}
AZURE_PASSWORD=${AZURE_PASSWORD}
AZURE_DATABASE=${AZURE_DATABASE}
AZURE_SSL_CA=${AZURE_SSL_CA}
EOF
    umask 022
    chmod 600 "$ENV_FILE"
    ok ".env written (mode 600)"
fi

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
.venv/
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

# mfrc522 declares "Requires-Dist: RPi.GPIO", but rpi-lgpio is what we actually
# want providing that module. pip resolves by distribution name, not module
# name, so installing rpi-lgpio first does not satisfy it: pip fetches the real
# RPi.GPIO anyway and it lands on top. RPi.GPIO also ships no wheel for
# python 3.11 or aarch64, so on Bookworm it COMPILES from source, and we would
# then delete it. Install mfrc522 with --no-deps and supply its real needs
# ourselves, so the real RPi.GPIO is never fetched at all.
REQ="${APP_DIR}/requirements.txt"
if [[ ! -f "$REQ" ]]; then
    warn "No requirements.txt found; skipping."
elif grep -qiE '^[[:space:]]*mfrc522([[:space:]]|;|$|[<>=!])' "$REQ"; then
    REQ_TMP="$(mktemp)"
    grep -viE '^[[:space:]]*mfrc522([[:space:]]|;|$|[<>=!])' "$REQ" >"$REQ_TMP" || true
    "${VENV_DIR}/bin/pip" install -q -r "$REQ_TMP" \
        || die "pip install failed. Scroll up for the failing package."
    rm -f "$REQ_TMP"
    "${VENV_DIR}/bin/pip" install -q --no-deps mfrc522 \
        || die "pip install of mfrc522 failed."
    "${VENV_DIR}/bin/pip" install -q rpi-lgpio spidev \
        || die "Could not install rpi-lgpio/spidev, which mfrc522 needs."
    ok "Requirements installed (mfrc522 --no-deps, GPIO via rpi-lgpio)"
    info "pip's 'mfrc522 requires RPi.GPIO' ERROR above is expected and harmless:"
    info "rpi-lgpio provides that module under a different distribution name,"
    info "which pip has no way to know. Nothing is actually missing."
else
    # mfrc522 is gone or its metadata was fixed: plain install.
    "${VENV_DIR}/bin/pip" install -q -r "$REQ" \
        || die "pip install failed. Scroll up for the failing package."
    "${VENV_DIR}/bin/pip" install -q rpi-lgpio spidev 2>/dev/null || true
    ok "Requirements installed"
fi

# Safety net: if the real RPi.GPIO is present anyway (someone ran
# `pip install --upgrade mfrc522` by hand), swap it back out. Uninstalling it
# deletes the shared RPi/ directory including rpi-lgpio's files while pip still
# records rpi-lgpio as installed, so both must go before reinstalling.
if compgen -G "${VENV_DIR}/lib/python*/site-packages/RPi/_GPIO*.so" >/dev/null; then
    warn "Real RPi.GPIO found; replacing it with rpi-lgpio."
    "${VENV_DIR}/bin/pip" uninstall -y -q RPi.GPIO rpi-gpio rpi-lgpio 2>/dev/null || true
    "${VENV_DIR}/bin/pip" install -q rpi-lgpio || warn "Could not reinstall rpi-lgpio."
fi

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
import importlib

# utils/hardware_stubs.py replaces any of these with a silent no-op fake when
# the real module is missing, so the app starts and appears healthy while the
# relay never fires and the LCD never lights. That makes a missing one far more
# dangerous than a crash. Check them WITHOUT importing hardware_stubs.
FAKEABLE = ("RPi.GPIO", "smbus2", "mfrc522", "spidev")
OTHER = ("dotenv", "dateutil", "pymysql")

faked, missing, hardware = [], [], []
for group, dest in ((FAKEABLE, faked), (OTHER, missing)):
    for mod in group:
        try:
            importlib.import_module(mod)
        except ImportError as e:
            dest.append(f"{mod}: {e}")
        except Exception as e:
            # Present but the hardware is not responding yet. Not a packaging problem.
            hardware.append(f"{mod}: {type(e).__name__}: {e}")

impl = "none"
try:
    import RPi, pathlib
    d = pathlib.Path(RPi.__file__).parent
    impl = "RPi.GPIO (real C extension)" if list(d.glob("_GPIO*.so")) else "rpi-lgpio"
except Exception:
    pass

print("FAKED:" + "|".join(faked))
print("MISSING:" + "|".join(missing))
print("HARDWARE:" + "|".join(hardware))
print("IMPL:" + impl)
PYCHECK
)" || true

GPIO_IMPL="$(printf '%s\n' "$VERIFY_OUT" | sed -n 's/^IMPL://p')"
FAKED_MODS="$(printf '%s\n' "$VERIFY_OUT" | sed -n 's/^FAKED://p')"
MISSING_MODS="$(printf '%s\n' "$VERIFY_OUT" | sed -n 's/^MISSING://p')"
HARDWARE_MODS="$(printf '%s\n' "$VERIFY_OUT" | sed -n 's/^HARDWARE://p')"

if [[ -n "$FAKED_MODS" ]]; then
    warn "MISSING HARDWARE MODULES. These do NOT crash the app."
    warn "utils/hardware_stubs.py substitutes silent no-op fakes, so the machine"
    warn "will look like it is working while the relay never fires:"
    printf '%s\n' "$FAKED_MODS" | tr '|' '\n' | sed 's/^/      /'
elif [[ -z "$MISSING_MODS" ]]; then
    ok "All Python imports resolve, with real hardware modules (no stubs)"
fi

info "GPIO implementation: ${GPIO_IMPL}"
if (( IS_PI5 )) && [[ "$GPIO_IMPL" == "RPi.GPIO"* ]]; then
    warn "This is a Pi 5 running the real RPi.GPIO, which fails at runtime."
    warn "rpi-lgpio did not take. Fix with, in this order:"
    warn "  ${VENV_DIR}/bin/pip uninstall -y RPi.GPIO && ${VENV_DIR}/bin/pip install rpi-lgpio"
fi
if [[ -n "$MISSING_MODS" ]]; then
    warn "Missing Python modules (these will stop the service):"
    printf '%s\n' "$MISSING_MODS" | tr '|' '\n' | sed 's/^/      /'
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

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
ok "${SERVICE_FILE} written"

sudo chown -R "${APP_USER}:${APP_USER}" "$APP_DIR"

sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}.service" >/dev/null 2>&1
ok "Service enabled"

if (( REBOOT_NEEDED )); then
    # Starting now would fail: lcd/RGB1602.py opens /dev/i2c-1 at import time,
    # and SPI/I2C do not exist until the reboot. Leave it enabled instead of
    # showing a failure that is not a real problem.
    warn "Not starting the service yet: SPI/I2C need a reboot first."
    info "It is enabled and will start automatically on boot."
else
    sudo systemctl restart "${SERVICE_NAME}.service"
    sleep 4
    step "Service status"
    sudo systemctl status "${SERVICE_NAME}.service" --no-pager --lines=15 || true
    if ! systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        warn "Service is not running. Last 20 journal lines:"
        journalctl -u "${SERVICE_NAME}.service" -n 20 --no-pager 2>/dev/null | sed 's/^/      /' || true
        printf '\n    Reproduce in the foreground with:\n'
        printf '      cd %s && ./.venv/bin/python main.py\n' "$APP_DIR"
    fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

if (( REBOOT_NEEDED )); then
    HEADLINE="${C_YELLOW}${C_BOLD}Install complete. Reboot required.${C_RESET}"
elif systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    HEADLINE="${C_GREEN}${C_BOLD}Setup complete. Service is running.${C_RESET}"
else
    HEADLINE="${C_YELLOW}${C_BOLD}Install complete, but the service is not running.${C_RESET}"
fi

cat <<EOF

${HEADLINE}

  Machine     ${MACHINE_ID} (${MACHINE_NAME})
  Install dir ${APP_DIR}
  Service     ${SERVICE_NAME}.service

  Service log    journalctl -u ${SERVICE_NAME}.service -f   <- tracebacks go here
  App log        tail -f ${APP_DIR}/logs/sync.log
  Run by hand    cd ${APP_DIR} && ./.venv/bin/python main.py
  Restart        sudo systemctl restart ${SERVICE_NAME}.service
  I2C check      i2cdetect -y 1      (expect 3e and 60)
  SPI check      ls -l /dev/spidev*
EOF

if (( REBOOT_NEEDED )); then
    printf '\n%s[action needed]%s SPI and I2C were just enabled and do not exist yet.\n' "$C_YELLOW" "$C_RESET"
    printf '    The service cannot start until you reboot. It will come up on its own after:\n\n      sudo reboot\n\n'
fi
