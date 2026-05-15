#!/bin/bash
set -euo pipefail

# USB Monitor -- installer
# Author: Dusan Panic <dpanic@gmail.com>
# Installs a udev rule + alert script that POSTs a webhook on every new
# USB device-add event. Allowlist is seeded from currently-connected
# devices (lsusb) at install time so the boot-time enumeration storm and
# already-plugged devices stay silent.
#
# Usage:
#   sudo ./monitor.sh <webhook-url>
#   sudo ./monitor.sh --update
#   sudo ./monitor.sh --uninstall

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_DIR/lib.sh"

ALERT_SCRIPT="/usr/local/bin/usb-monitor-alert.sh"
DIGEST_SCRIPT="/usr/local/bin/usb-monitor-digest.sh"
STATE_DIR="/var/lib/usb-monitor"
RULE_PATH="/etc/udev/rules.d/99-usb-monitor.rules"
DIGEST_SERVICE="/etc/systemd/system/usb-monitor-digest.service"
DIGEST_TIMER="/etc/systemd/system/usb-monitor-digest.timer"
DIGEST_INTERVAL="1h"

if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root (sudo)."
    exit 1
fi

parse_update_flag "$@"
WEBHOOK_URL="${_CLEAN_ARGS[0]:-}"

# ── Uninstall ───────────────────────────────────────────────────────────────

if [[ "$UNINSTALL" == true ]]; then
    echo "=== USB Monitor -- Remove ==="
    echo ""
    echo "[1/4] Stopping and disabling digest timer..."
    systemctl disable usb-monitor-digest.timer 2>/dev/null || true
    systemctl stop usb-monitor-digest.timer 2>/dev/null || true
    rm -f "$DIGEST_SERVICE" "$DIGEST_TIMER"
    systemctl daemon-reload
    echo "  done."

    echo "[2/4] Removing udev rule..."
    rm -f "$RULE_PATH"
    udevadm control --reload 2>/dev/null || true
    echo "  done."

    echo "[3/4] Removing files..."
    rm -f "$ALERT_SCRIPT" "$DIGEST_SCRIPT"
    rm -rf "$STATE_DIR"
    echo "  done."

    echo "[4/4] Status..."
    echo "  USB Monitor removed."

    echo ""
    echo "=== USB Monitor removal complete ==="
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

echo "=== USB Monitor Setup ==="
echo "  Trigger:  udev rule (real-time)"
echo "  Digest:   systemd timer every ${DIGEST_INTERVAL}"
echo "  Webhook:  ${WEBHOOK_URL:0:50}..."
echo ""

echo "[1/6] Creating state directory..."
mkdir -p "$STATE_DIR"
echo "$WEBHOOK_URL" > "$STATE_DIR/webhook-url"
chmod 600 "$STATE_DIR/webhook-url"
echo "  done."

echo "[2/6] Allowlist setup..."
ALLOW_FILE="$STATE_DIR/allow"
DEFAULTS_FILE="$SCRIPT_DIR/allow-devices.defaults"

SEEDED=0
if [[ -f "$ALLOW_FILE" ]]; then
    EXISTING=$(grep -cE '^[0-9a-f]{4}:[0-9a-f]{4}$' "$ALLOW_FILE" || true)
    echo "  preserving existing allowlist (${EXISTING} entries)"
else
    # First install: seed from currently-connected devices via `lsusb`.
    cp "$DEFAULTS_FILE" "$ALLOW_FILE"
    if command -v lsusb &>/dev/null; then
        while IFS= read -r vidpid; do
            [[ -z "$vidpid" ]] && continue
            [[ "$vidpid" =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]] || continue
            echo "$vidpid" >> "$ALLOW_FILE"
            SEEDED=$(( SEEDED + 1 ))
        done < <(lsusb | awk '{print $6}' | sort -u)
        echo "  seeded ${SEEDED} VID:PID entries from lsusb (first install)"
    else
        echo "  WARNING: lsusb not found, allowlist not seeded -- every device will alert"
        echo "  Install with: sudo apt-get install usbutils"
    fi
fi
echo "  done."

echo "[3/6] Installing alert script to $ALERT_SCRIPT..."
cp "$SCRIPT_DIR/alert.sh" "$ALERT_SCRIPT"
chmod +x "$ALERT_SCRIPT"
echo "  done."

echo "[4/6] Installing udev rule to $RULE_PATH..."
cp "$SCRIPT_DIR/99-usb-monitor.rules" "$RULE_PATH"
chmod 644 "$RULE_PATH"
udevadm control --reload
echo "  done."

echo "[5/6] Installing digest script + systemd timer..."
cp "$SCRIPT_DIR/digest.sh" "$DIGEST_SCRIPT"
chmod +x "$DIGEST_SCRIPT"

cat > "$DIGEST_SERVICE" << EOF
[Unit]
Description=USB Monitor hourly digest

[Service]
Type=oneshot
ExecStart=$DIGEST_SCRIPT
EOF

cat > "$DIGEST_TIMER" << EOF
[Unit]
Description=USB Monitor digest -- every ${DIGEST_INTERVAL}

[Timer]
OnBootSec=5min
OnUnitActiveSec=${DIGEST_INTERVAL}
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now usb-monitor-digest.timer
echo "  done."

echo "[6/6] Sending test message..."
ACTIVATE_MSG=":white_check_mark: **USB Monitor activated**"
ACTIVATE_MSG+=$'\n\n'"| Setting | Value |"
ACTIVATE_MSG+=$'\n'"| --- | --- |"
ACTIVATE_MSG+=$'\n'"| Hostname | \`$(hostname)\` |"
ACTIVATE_MSG+=$'\n'"| Trigger | udev rule (real-time) |"
ALLOW_COUNT=$(grep -cE '^[0-9a-f]{4}:[0-9a-f]{4}$' "$ALLOW_FILE" 2>/dev/null || echo 0)
ACTIVATE_MSG+=$'\n'"| Allowlist | ${ALLOW_COUNT} trusted devices |"
ACTIVATE_MSG+=$'\n'"| Burst limit | max 3 alerts per 5 min |"
ACTIVATE_MSG+=$'\n'"| Digest | every ${DIGEST_INTERVAL} (catches suppressed events) |"
ACTIVATE_JSON=$(printf '%s' "$ACTIVATE_MSG" | sed 's/\\/\\\\/g; s/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"USB Monitor\",\"icon_emoji\":\":electric_plug:\",\"text\":\"${ACTIVATE_JSON}\"}")

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "  webhook test: OK (HTTP $HTTP_CODE)"
else
    echo "  webhook test: FAILED (HTTP $HTTP_CODE) -- check the URL"
fi
echo "  done."

echo ""
echo "=== USB Monitor setup complete ==="
echo ""
echo "  Rule:        $RULE_PATH"
echo "  Allowlist:   $ALLOW_FILE  (${ALLOW_COUNT} entries)"
echo "  Events log:  ${STATE_DIR}/events.log"
echo "  Digest:      systemctl list-timers usb-monitor-digest.timer"
echo "  Logs:        journalctl -t usb-monitor -f"
echo "  Live udev:   sudo udevadm monitor --environment --udev"
echo ""
echo "Alerts fire when:"
echo "  - A USB device is plugged in whose VID:PID is NOT in the allowlist"
echo "  - Up to 3 alerts per 5 min; extras logged + delivered via hourly digest"
echo ""
echo "To trust a new device after it alerts:"
echo "  echo 'VID:PID' | sudo tee -a $ALLOW_FILE"
echo ""
echo "To run the digest manually (e.g. after a busy period):"
echo "  sudo $DIGEST_SCRIPT"
