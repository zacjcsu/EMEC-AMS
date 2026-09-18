#!/usr/bin/env bash
#
# EMEC-AMS updater / first-boot provisioner
#
# Lives in the repo and is deployed to /home/emec/emec-ams/emecamsupdate.sh.
# Install its systemd units once on the golden image:
#
#     sudo /home/emec/emec-ams/emecamsupdate.sh --install
#
# Then it runs from three triggers, all hitting the same unit:
#   - boot            emec-ams-update.timer  (OnBootSec)
#   - daily 01:00     emec-ams-update.timer  (OnCalendar, system timezone)
#   - card scan       emec-ams-update.path   (watches .update-requested)
#
# Three states, decided at run time:
#   config.json blank              -> WAIT      do nothing, exit clean
#   config.json filled, app disabled -> PROVISION apply identity, sync, enable, reboot
#   config.json filled, app enabled  -> UPDATE    stop, sync, start
#
# Safe to run at any time, from any trigger, concurrently.

set -euo pipefail

APP_USER="${APP_USER:-emec}"
APP_DIR="${APP_DIR:-/home/${APP_USER}/emec-ams}"
VENV_DIR="${APP_DIR}/.venv"
SERVICE="emec-ams.service"
CONFIG="${APP_DIR}/config/config.json"
FLAG="${APP_DIR}/.update-requested"
LOCK="/run/emec-ams-update.lock"
LOGFILE="${APP_DIR}/logs/update.log"

REPO="${REPO:-https://github.com/zacjcsu/EMEC-AMS.git}"
BRANCH="${BRANCH:-main}"

# Provisioning ends with a reboot so the new hostname and machine-id take
# effect cleanly. Set PROVISION_REBOOT=0 to skip it.
PROVISION_REBOOT="${PROVISION_REBOOT:-1}"

UNIT_DIR=/etc/systemd/system

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# --install: write the systemd units and enable them
# ---------------------------------------------------------------------------

install_units() {
    [[ "$(id -u)" -eq 0 ]] || die "--install must run as root (use sudo)."

    cat >"${UNIT_DIR}/emec-ams-update.service" <<EOF
[Unit]
Description=EMEC-AMS update and first-boot provisioning
After=network-online.target
Wants=network-online.target
# A path unit re-checks the moment its service exits, so a flag file left
# behind by a bug would restart this instantly. Cap the damage.
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=oneshot
ExecStart=${APP_DIR}/emecamsupdate.sh
# Long enough for a pip install on a slow link, short enough to not hang forever.
TimeoutStartSec=900
EOF

    cat >"${UNIT_DIR}/emec-ams-update.timer" <<EOF
[Unit]
Description=EMEC-AMS update schedule

[Timer]
# Shortly after boot, once the network has had a chance to come up.
OnBootSec=3min
# Daily at 01:00 in the system timezone. With the Pi set to America/Denver this
# tracks DST automatically, so it is 01:00 local year round.
OnCalendar=*-*-* 01:00:00
# If the Pi was powered off at 01:00, run once on the next boot instead.
Persistent=true
# Stagger fleet-wide so twenty Pis do not hit GitHub in the same second.
RandomizedDelaySec=300
Unit=emec-ams-update.service

[Install]
WantedBy=timers.target
EOF

    cat >"${UNIT_DIR}/emec-ams-update.path" <<EOF
[Unit]
Description=EMEC-AMS update requested by the application

[Path]
# main.py touches this file. systemd starts the update service in its own
# cgroup, which is what lets it stop emec-ams without killing itself.
PathExists=${FLAG}
Unit=emec-ams-update.service

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now emec-ams-update.timer >/dev/null
    systemctl enable --now emec-ams-update.path >/dev/null

    log "Installed and enabled:"
    log "  ${UNIT_DIR}/emec-ams-update.service"
    log "  ${UNIT_DIR}/emec-ams-update.timer   (boot + daily 01:00 local)"
    log "  ${UNIT_DIR}/emec-ams-update.path    (watches ${FLAG})"
    exit 0
}

[[ "${1:-}" == "--install" ]] && install_units

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

[[ "$(id -u)" -eq 0 ]] || die "Must run as root. It is started by systemd; to run by hand use: sudo systemctl start emec-ams-update.service"
[[ -d "$APP_DIR" ]] || die "${APP_DIR} does not exist."

mkdir -p "${APP_DIR}/logs"
exec > >(tee -a "$LOGFILE") 2>&1

# Clear the request flag before anything that can exit early. systemd re-checks
# a path unit the instant its triggered service terminates, so ANY exit that
# leaves this file behind restarts the script immediately, in a tight loop.
rm -f "$FLAG"

# Serialise against a manual run overlapping the timer. systemd already
# prevents two instances of the unit, this covers direct invocation.
exec 9>"$LOCK"
flock -n 9 || { log "Another update is already running; exiting."; exit 0; }

as_app() { runuser -u "$APP_USER" -- "$@"; }

# ---------------------------------------------------------------------------
# Decide state
# ---------------------------------------------------------------------------

read_config() {
    python3 - "$CONFIG" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
for k in ("machine_id", "machine_name", "machine_type"):
    v = d.get(k)
    print(str(v).strip() if v is not None else "")
PY
}

MACHINE_ID=""; MACHINE_NAME=""; MACHINE_TYPE=""
{ read -r MACHINE_ID; read -r MACHINE_NAME; read -r MACHINE_TYPE; } < <(read_config) || true

if [[ -z "$MACHINE_ID" || -z "$MACHINE_NAME" || -z "$MACHINE_TYPE" ]]; then
    log "config.json is not filled in yet (machine_id='${MACHINE_ID}'). Waiting."
    log "Nothing to do without an identity. Fill in ${CONFIG} and this will"
    log "provision on the next trigger, or force one now with:"
    log "  sudo systemctl start emec-ams-update.service"
    exit 0
fi

if systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
    MODE=update
else
    MODE=provision
fi
log "Machine ${MACHINE_ID} (${MACHINE_NAME}) — mode: ${MODE}"

# ---------------------------------------------------------------------------
# Code sync
# ---------------------------------------------------------------------------

sync_code() {
    # Adopt the directory if the setup script rsynced it in without .git.
    if [[ ! -d "${APP_DIR}/.git" ]]; then
        log "No git repo here yet; adopting ${APP_DIR} in place."
        as_app git -C "$APP_DIR" init -q -b "$BRANCH"
    fi

    # REPO is authoritative. Without set-url an existing checkout would keep
    # fetching whatever remote it was created with, so moving the repo would
    # silently do nothing.
    if as_app git -C "$APP_DIR" remote get-url origin >/dev/null 2>&1; then
        as_app git -C "$APP_DIR" remote set-url origin "$REPO"
    else
        as_app git -C "$APP_DIR" remote add origin "$REPO"
    fi

    local before after
    before="$(sha256sum "${APP_DIR}/requirements.txt" 2>/dev/null | cut -d' ' -f1 || true)"

    log "Fetching ${REPO} (${BRANCH})..."
    if ! as_app git -C "$APP_DIR" fetch --quiet origin "$BRANCH"; then
        log "WARNING: fetch failed (offline?). Keeping the code that is here."
        return 1
    fi

    # reset --hard, not pull: no merge conflicts from local edits, and it never
    # touches untracked files, so .env, config.json, .venv, logs and data stay.
    as_app git -C "$APP_DIR" reset --hard --quiet FETCH_HEAD
    log "Now at $(as_app git -C "$APP_DIR" log -1 --pretty='%h %s')"

    after="$(sha256sum "${APP_DIR}/requirements.txt" 2>/dev/null | cut -d' ' -f1 || true)"
    if [[ "$before" != "$after" || ! -x "${VENV_DIR}/bin/python" ]]; then
        log "requirements.txt changed (or no venv); installing dependencies."
        [[ -x "${VENV_DIR}/bin/python" ]] || as_app python3 -m venv "$VENV_DIR"
        install_python_deps
    fi
    ensure_gpio

    verify_hardware_modules

    compat_fix
    prune_hardware
    chown -R "${APP_USER}:${APP_USER}" "$APP_DIR"
    return 0
}

# utils/hardware_stubs.py swaps in silent no-op fakes for any missing hardware
# module, so the service starts clean while the relay never fires and the LCD
# stays dark. A missing module is worse than a crash because nothing reports it.
# Checked without importing hardware_stubs, which would install the fakes.
HW_CHECK_PY='
import importlib
bad = []
for mod in ("RPi.GPIO", "smbus2", "mfrc522", "spidev", "dotenv", "pymysql"):
    try:
        importlib.import_module(mod)
    except ImportError as e:
        bad.append("%s: %s" % (mod, e))
    except Exception:
        pass
impl = "?"
try:
    import RPi, pathlib
    d = pathlib.Path(RPi.__file__).parent
    impl = "RPi.GPIO (real)" if list(d.glob("_GPIO*.so")) else "rpi-lgpio"
except Exception:
    impl = "none"
print("|".join(bad))
print("IMPL:" + impl)
'

hw_check() {
    (cd "$APP_DIR" && printf '%s' "$HW_CHECK_PY" | "${VENV_DIR}/bin/python" - 2>/dev/null) || true
}

verify_hardware_modules() {
    local out
    local raw impl
    raw="$(hw_check)"
    impl="$(sed -n 's/^IMPL://p' <<<"$raw")"
    out="$(grep -v '^IMPL:' <<<"$raw" | head -1)"
    [[ -z "$out" ]] && { log "Hardware modules present. GPIO implementation: ${impl}"; return 0; }

    log "Hardware modules missing, attempting repair:"
    printf '%s\n' "$out" | tr '|' '\n' | sed 's/^/      /'
    install_python_deps
    ensure_gpio

    out="$(hw_check | grep -v '^IMPL:' | head -1)"
    if [[ -z "$out" ]]; then
        log "Repaired; all hardware modules now present."
    else
        log "WARNING: STILL MISSING after repair. hardware_stubs.py will substitute"
        log "silent no-op fakes, so this machine will look healthy and do nothing:"
        printf '%s\n' "$out" | tr '|' '\n' | sed 's/^/      /'
    fi
}

install_python_deps() {
    # mfrc522 declares "Requires-Dist: RPi.GPIO", but rpi-lgpio is what we want
    # providing that module. pip resolves by distribution name, not module name,
    # so installing rpi-lgpio first does not satisfy it. RPi.GPIO also ships no
    # wheel for python 3.11 or aarch64, so on Bookworm it compiles from source.
    # Install mfrc522 with --no-deps and supply its real needs ourselves, so the
    # real RPi.GPIO is never fetched at all.
    local req="${APP_DIR}/requirements.txt" tmp
    [[ -f "$req" ]] || { log "No requirements.txt; skipping dependencies."; return 0; }

    if grep -qiE '^[[:space:]]*mfrc522([[:space:]]|;|$|[<>=!])' "$req"; then
        tmp="$(mktemp)"
        # This script runs as root but pip runs as APP_USER, so the filtered
        # file must be readable by them. mktemp creates it 0600 root-owned.
        chmod 0644 "$tmp"
        grep -viE '^[[:space:]]*mfrc522([[:space:]]|;|$|[<>=!])' "$req" >"$tmp" || true
        as_app "${VENV_DIR}/bin/pip" install -q -r "$tmp" || log "WARNING: pip install failed."
        rm -f "$tmp"
        as_app "${VENV_DIR}/bin/pip" install -q --no-deps mfrc522 || log "WARNING: mfrc522 install failed."
        as_app "${VENV_DIR}/bin/pip" install -q rpi-lgpio spidev || log "WARNING: rpi-lgpio/spidev install failed."
        # pip prints "mfrc522 requires RPi.GPIO, which is not installed" on every
        # run. That is expected and correct: rpi-lgpio provides that module under
        # a different distribution name, which pip has no way to know.
        log "(pip's 'mfrc522 requires RPi.GPIO' notice is expected; rpi-lgpio provides it.)"
    else
        as_app "${VENV_DIR}/bin/pip" install -q -r "$req" || log "WARNING: pip install failed."
        as_app "${VENV_DIR}/bin/pip" install -q rpi-lgpio spidev 2>/dev/null || true
    fi
}

ensure_gpio() {
    # Safety net only. Nothing above installs the real RPi.GPIO any more, but a
    # manual `pip install --upgrade mfrc522` would. Uninstalling it deletes the
    # shared RPi/ directory including rpi-lgpio's files while pip still records
    # rpi-lgpio as installed, so both must go before reinstalling.
    compgen -G "${VENV_DIR}/lib/python*/site-packages/RPi/_GPIO*.so" >/dev/null || return 0
    log "Real RPi.GPIO found; replacing it with rpi-lgpio."
    as_app "${VENV_DIR}/bin/pip" uninstall -y -q RPi.GPIO rpi-gpio rpi-lgpio 2>/dev/null || true
    as_app "${VENV_DIR}/bin/pip" install -q rpi-lgpio 2>/dev/null \
        || log "WARNING: could not reinstall rpi-lgpio."
}

prune_hardware() {
    # hardware/ is ~8.7MB of KiCad and gerber files, none of which the Pi runs.
    # git reset --hard restores it every sync, so tell git to ignore that path
    # and delete it. skip-worktree survives future resets.
    if [[ -d "${APP_DIR}/hardware" ]]; then
        as_app git -C "$APP_DIR" ls-files -z hardware \
            | as_app xargs -0 -r git -C "$APP_DIR" update-index --skip-worktree 2>/dev/null || true
        rm -rf "${APP_DIR}/hardware"
        log "Pruned hardware/ (KiCad and gerbers, not needed at runtime)."
    fi
}

compat_fix() {
    # lcd/RGB1602.py imports `smbus`, requirements.txt ships `smbus2`. A
    # reset --hard reverts the fix every time, so re-apply it. Harmless once
    # the import is corrected in the repo.
    local f="${APP_DIR}/lcd/RGB1602.py"
    if [[ -f "$f" ]] && grep -q '^from smbus import SMBus' "$f" \
       && ! "${VENV_DIR}/bin/python" -c 'import smbus' 2>/dev/null; then
        sed -i 's/^from smbus import SMBus/from smbus2 import SMBus/' "$f"
        log "Re-applied smbus2 import fix to lcd/RGB1602.py (fix this upstream)."
    fi
}

# ---------------------------------------------------------------------------
# PROVISION
# ---------------------------------------------------------------------------

provision() {
    # Hostname from machine_id: lowercase, only [a-z0-9-], no leading/trailing
    # dash, max 63 chars.
    local host
    host="$(printf '%s' "$MACHINE_ID" | tr '[:upper:]' '[:lower:]' \
            | tr -c 'a-z0-9-' '-' | sed 's/^-*//; s/-*$//' | cut -c1-63)"
    [[ -n "$host" ]] || die "Could not derive a hostname from machine_id '${MACHINE_ID}'."

    log "Setting hostname to '${host}'."
    hostnamectl set-hostname "$host"
    if grep -q '^127\.0\.1\.1' /etc/hosts; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${host}/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$host" >>/etc/hosts
    fi

    log "Regenerating SSH host keys."
    rm -f /etc/ssh/ssh_host_*
    ssh-keygen -A >/dev/null
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

    log "Regenerating machine-id."
    truncate -s 0 /etc/machine-id
    rm -f /var/lib/dbus/machine-id
    systemd-machine-id-setup >/dev/null
    command -v dbus-uuidgen >/dev/null && dbus-uuidgen --ensure 2>/dev/null || true

    log "Clearing state carried over from the golden image."
    rm -f "${APP_DIR}/data/local.db"
    rm -f "${APP_DIR}"/logs/*.log "${APP_DIR}"/logs/*.log.*
    find "$APP_DIR" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
    mkdir -p "${APP_DIR}/data" "${APP_DIR}/logs"

    sync_code || log "Continuing with the code already present."

    log "Enabling ${SERVICE}."
    systemctl enable "$SERVICE" >/dev/null

    chown -R "${APP_USER}:${APP_USER}" "$APP_DIR"
    log "Provisioning complete for ${MACHINE_ID}."

    if (( PROVISION_REBOOT )); then
        log "Rebooting so the hostname and machine-id take effect."
        sleep 2
        systemctl reboot
    else
        log "PROVISION_REBOOT=0, starting the service without rebooting."
        systemctl start "$SERVICE"
    fi
}

# ---------------------------------------------------------------------------
# UPDATE
# ---------------------------------------------------------------------------

update() {
    log "Stopping ${SERVICE}."
    systemctl stop "$SERVICE" || true

    # Whatever happens below, the machine must not be left with the app down.
    trap 'log "Starting ${SERVICE}."; systemctl start "$SERVICE" || log "ERROR: could not start ${SERVICE}."' EXIT

    sync_code || log "Continuing with the code already present."

    log "Update complete."
}

case "$MODE" in
    provision) provision ;;
    update)    update ;;
esac
