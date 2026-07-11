#!/bin/bash
set -euo pipefail

# AppArmor Continuous Monitor -- installer
# Author: Dusan Panic <dpanic@gmail.com>
# Installs apparmor-monitor.sh + systemd timer that checks for AppArmor
# violations and sends webhook alerts when security issues are detected.
#
# Usage:
#   sudo ./monitor.sh <webhook-url>
#   sudo ./monitor.sh --update
#   sudo ./monitor.sh --uninstall

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_DIR/lib.sh"

MONITOR_SCRIPT="/usr/local/bin/apparmor-monitor.sh"
STATE_DIR="/var/lib/apparmor-monitor"
SERVICE_PATH="/etc/systemd/system/apparmor-monitor.service"
TIMER_PATH="/etc/systemd/system/apparmor-monitor.timer"
CHECK_INTERVAL="15min"

if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root (sudo)."
    exit 1
fi

# Parse webhook URL from positional args (--update/--uninstall handled by lib.sh)
parse_update_flag "$@"
WEBHOOK_URL="${_CLEAN_ARGS[0]:-}"

# ── Uninstall ───────────────────────────────────────────────────────────────

if [[ "$UNINSTALL" == true ]]; then
    echo "=== AppArmor Monitor -- Remove ==="
    echo ""
    echo "[1/3] Stopping and disabling timer..."
    systemctl disable apparmor-monitor.timer 2>/dev/null || true
    systemctl stop apparmor-monitor.timer 2>/dev/null || true
    echo "  done."

    echo "[2/3] Removing files..."
    rm -f "$SERVICE_PATH" "$TIMER_PATH" "$MONITOR_SCRIPT"
    rm -rf "$STATE_DIR"
    systemctl daemon-reload
    echo "  done."

    echo "[3/3] Status..."
    echo "  Timer removed, monitoring disabled."

    echo ""
    echo "=== AppArmor Monitor removal complete ==="
    exit 0
fi

# ── Resolve webhook URL ────────────────────────────────────────────────────

if [[ -z "$WEBHOOK_URL" && -f "$STATE_DIR/webhook-url" ]]; then
    WEBHOOK_URL="$(cat "$STATE_DIR/webhook-url")"
fi

if [[ -z "$WEBHOOK_URL" ]]; then
    echo "Error: webhook URL is required."
    echo "Usage: sudo $0 <webhook-url>"
    exit 1
fi

# ── Install / Update ───────────────────────────────────────────────────────

echo "=== AppArmor Continuous Monitor Setup ==="
echo "  Check interval: every ${CHECK_INTERVAL}"
echo "  Webhook: ${WEBHOOK_URL:0:50}..."
echo ""

echo "[1/5] Creating state directory..."
mkdir -p "$STATE_DIR"
echo "$WEBHOOK_URL" > "$STATE_DIR/webhook-url"
chmod 600 "$STATE_DIR/webhook-url"

aa-status --json 2>/dev/null > "$STATE_DIR/baseline.json" || \
    aa-status 2>/dev/null > "$STATE_DIR/baseline.txt" || true

date +%s > "$STATE_DIR/last-check"

IGNORE_FILE="$STATE_DIR/ignore-profiles"
DEFAULTS_FILE="$SCRIPT_DIR/ignore-profiles.defaults"
if [[ ! -f "$IGNORE_FILE" ]]; then
    cp "$DEFAULTS_FILE" "$IGNORE_FILE"
    echo "  created ignore-profiles with defaults"
else
    while IFS= read -r entry; do
        [[ -z "$entry" || "$entry" == \#* ]] && continue
        if ! grep -qxF "$entry" "$IGNORE_FILE"; then
            echo "$entry" >> "$IGNORE_FILE"
            echo "  added ignore rule: $entry"
        fi
    done < "$DEFAULTS_FILE"
fi
echo "  done."

echo "[2/5] Installing monitor script to $MONITOR_SCRIPT..."
cp "$SCRIPT_DIR/check.sh" "$MONITOR_SCRIPT"
chmod +x "$MONITOR_SCRIPT"
echo "  done."

echo "[3/5] Creating systemd service and timer..."
cat > "$SERVICE_PATH" << EOF
[Unit]
Description=AppArmor violation monitor (webhook alerts)
After=apparmor.service

[Service]
Type=oneshot
ExecStart=$MONITOR_SCRIPT
EOF

cat > "$TIMER_PATH" << EOF
[Unit]
Description=AppArmor monitor -- check every ${CHECK_INTERVAL}

[Timer]
OnBootSec=5min
OnUnitActiveSec=${CHECK_INTERVAL}
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now apparmor-monitor.timer
echo "  done."

echo "[4/5] Sending test message..."
ACTIVATE_MSG=":white_check_mark: **AppArmor monitor activated**"
ACTIVATE_MSG+=$'\n\n'"| Setting | Value |"
ACTIVATE_MSG+=$'\n'"| --- | --- |"
ACTIVATE_MSG+=$'\n'"| Hostname | \`$(hostname)\` |"
ACTIVATE_MSG+=$'\n'"| Interval | every ${CHECK_INTERVAL} |"
ACTIVATE_MSG+=$'\n'"| Alerts | DENIED, ALLOWED, tamper, service down |"
ACTIVATE_MSG+=$'\n'"| Rate limit | max 1 alert per 5 min |"
ACTIVATE_JSON=$(printf '%s' "$ACTIVATE_MSG" | sed 's/\\/\\\\/g; s/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"AppArmor Monitor\",\"icon_emoji\":\":shield:\",\"text\":\"${ACTIVATE_JSON}\"}")

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "  webhook test: OK (HTTP $HTTP_CODE)"
else
    echo "  webhook test: FAILED (HTTP $HTTP_CODE) -- check the URL"
fi
echo "  done."

echo "[5/5] Running initial check..."
bash "$MONITOR_SCRIPT" 2>&1 || true
echo "  done."

echo ""
echo "=== AppArmor Monitor setup complete ==="
echo ""
echo "  Timer:   systemctl status apparmor-monitor.timer"
echo "  Logs:    journalctl -u apparmor-monitor.service"
echo "  Manual:  sudo $MONITOR_SCRIPT"
echo ""
echo "Checks run every ${CHECK_INTERVAL}. Alerts sent when:"
echo "  - DENIED events detected (enforce mode blocks)"
echo "  - Profile state changes (possible tampering)"
echo "  - AppArmor service goes down"
echo ""
echo "ALLOWED events (complain mode) are logged but don't trigger alerts."
