#!/bin/bash
set -euo pipefail

# AppArmor release watcher -- installer
# Author: Dusan Panic <dpanic@gmail.com>
# Installs apparmor-version-check.sh + a 30-day systemd timer that pushes an
# ntfy alert when a non-prerelease apparmor lands, or when a package upgrade
# puts the allow-everything naming stubs back into complain mode.
#
# Usage:
#   sudo ./version-watch.sh [/path/to/.envrc]
#   sudo ./version-watch.sh --update
#   sudo ./version-watch.sh --uninstall

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_DIR/lib.sh"

CHECK_SCRIPT="/usr/local/bin/apparmor-version-check.sh"
STATE_DIR="/var/lib/apparmor-version-watch"
ENV_FILE="/etc/apparmor-version-watch.env"
SERVICE_PATH="/etc/systemd/system/apparmor-version-watch.service"
TIMER_PATH="/etc/systemd/system/apparmor-version-watch.timer"
CHECK_INTERVAL="30d"

if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root (sudo)."
    exit 1
fi

parse_update_flag "$@"
ENVRC="${_CLEAN_ARGS[0]:-/home/user/projects/1681377694/.envrc}"

# ── Uninstall ───────────────────────────────────────────────────────────────

if [[ "$UNINSTALL" == true ]]; then
    echo "=== AppArmor Release Watcher -- Remove ==="
    remove "stopping and disabling timer"
    systemctl disable apparmor-version-watch.timer 2>/dev/null || true
    systemctl stop apparmor-version-watch.timer 2>/dev/null || true
    remove "removing files"
    rm -f "$SERVICE_PATH" "$TIMER_PATH" "$CHECK_SCRIPT" "$ENV_FILE"
    rm -rf "$STATE_DIR"
    systemctl daemon-reload
    echo "  done."
    exit 0
fi

echo "=== AppArmor Release Watcher Setup ==="
echo "  Check interval: every ${CHECK_INTERVAL}"
echo ""

echo "[1/5] Creating state directory..."
mkdir -p "$STATE_DIR"
echo "  done."

echo "[2/5] Rendering ntfy credentials to $ENV_FILE..."
# Credentials live only in .envrc; render them into a root-only env file so the
# timer can alert without the repo ever carrying a secret.
if [[ ! -r "$ENVRC" ]]; then
    echo "  Error: cannot read $ENVRC -- pass the path as the first argument."
    exit 1
fi
set -a
# shellcheck source=/dev/null
. "$ENVRC"
set +a
: "${NTFY_URL:?NTFY_URL missing from $ENVRC}"
: "${NTFY_TOPIC:?NTFY_TOPIC missing from $ENVRC}"
: "${NTFY_AUTH:?NTFY_AUTH missing from $ENVRC}"

umask 077
cat > "$ENV_FILE" << EOF
NTFY_URL=${NTFY_URL}
NTFY_TOPIC=${NTFY_TOPIC}
NTFY_AUTH=${NTFY_AUTH}
EOF
chmod 600 "$ENV_FILE"
echo "  done (mode 600, values not echoed)."

echo "[3/5] Installing check script to $CHECK_SCRIPT..."
cp "$SCRIPT_DIR/version-check.sh" "$CHECK_SCRIPT"
chmod +x "$CHECK_SCRIPT"
echo "  done."

echo "[4/5] Creating systemd service and timer..."
cat > "$SERVICE_PATH" << EOF
[Unit]
Description=AppArmor release watcher (non-beta available / complain regression)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$CHECK_SCRIPT
EOF

# Persistent=true so a missed window fires after the next boot rather than
# silently skipping a whole 30-day cycle on a workstation that gets shut down.
cat > "$TIMER_PATH" << EOF
[Unit]
Description=AppArmor release watcher -- check every ${CHECK_INTERVAL}

[Timer]
OnBootSec=10min
OnUnitActiveSec=${CHECK_INTERVAL}
AccuracySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now apparmor-version-watch.timer
echo "  done."

echo "[5/5] Running initial check..."
bash "$CHECK_SCRIPT" 2>&1 || true
echo "  done."

echo ""
echo "=== AppArmor Release Watcher setup complete ==="
echo ""
echo "  Timer:   systemctl list-timers apparmor-version-watch.timer"
echo "  Logs:    journalctl -u apparmor-version-watch.service"
echo "  Manual:  sudo $CHECK_SCRIPT"
echo ""
echo "Alerts (ntfy topic from .envrc) fire when:"
echo "  - a non-prerelease apparmor becomes installable      (priority high)"
echo "  - a non-prerelease apparmor is staged in -proposed   (priority default)"
echo "  - naming stubs are back in complain mode             (priority urgent)"
