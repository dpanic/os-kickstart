#!/bin/bash
set -euo pipefail

# AppArmor Learning Mode Setup
# Author: Dusan Panic <dpanic@gmail.com>
# Installs utils, switches all profiles to complain mode,
# sets up a systemd timer to send a Slack reminder after 7 days.
# Does NOT auto-enforce -- you review and enforce manually.
#
# Usage:
#   sudo ./apparmor-setup.sh <slack-webhook-url>
#
# Example:
#   sudo ./apparmor-setup.sh https://hooks.slack.com/services/T.../B.../xxx

if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root (sudo)."
    exit 1
fi

# Parse flags and positional args
WEBHOOK_URL=""
MODE=""
for arg in "$@"; do
    case "$arg" in
        --uninstall) MODE="uninstall" ;;
        --update)    MODE="update" ;;
        *)           WEBHOOK_URL="$arg" ;;
    esac
done

LEARNING_DAYS=7
SCRIPT_PATH="/usr/local/bin/apparmor-remind.sh"
SERVICE_PATH="/etc/systemd/system/apparmor-enforce.service"
TIMER_PATH="/etc/systemd/system/apparmor-enforce.timer"

# Handle --uninstall
if [[ "$MODE" == "uninstall" ]]; then
    echo "=== AppArmor -- Revert ==="
    echo ""
    echo "[1/3] Switching all profiles back to enforce mode..."
    aa-enforce /etc/apparmor.d/* 2>&1 | tail -5 || true
    echo "  done."

    echo "[2/3] Removing reminder script and timer..."
    systemctl disable apparmor-enforce.timer 2>/dev/null || true
    systemctl stop apparmor-enforce.timer 2>/dev/null || true
    rm -f "$SERVICE_PATH" "$TIMER_PATH" "$SCRIPT_PATH"
    systemctl daemon-reload
    echo "  done."

    echo "[3/3] Status..."
    aa-status 2>/dev/null | head -10 || true

    echo ""
    echo "=== AppArmor revert complete ==="
    exit 0
fi

# On update without webhook arg, read it from the existing installed script
if [[ -z "$WEBHOOK_URL" && -f "$SCRIPT_PATH" ]]; then
    WEBHOOK_URL=$(grep -oP '^WEBHOOK_URL="\K[^"]+' "$SCRIPT_PATH" 2>/dev/null || true)
fi

if [[ -z "$WEBHOOK_URL" ]]; then
    echo "Error: Slack webhook URL is required."
    echo "Usage: sudo $0 <webhook-url>"
    exit 1
fi

echo "=== AppArmor Learning Mode Setup ==="
echo "  Learning period: ${LEARNING_DAYS} days"
echo "  Webhook: ${WEBHOOK_URL:0:50}..."
echo ""

echo "[1/5] Installing apparmor-utils and extra profiles..."
apt-get install -y apparmor-utils apparmor-profiles apparmor-profiles-extra
echo "  done."

echo "[2/5] Switching all profiles to complain (learning) mode..."
aa-complain /etc/apparmor.d/* 2>&1 | tail -5
echo ""
COMPLAIN_COUNT=$(aa-status 2>/dev/null | grep -c "complain" || echo "?")
ENFORCE_COUNT=$(aa-status 2>/dev/null | grep -c "enforce" || echo "?")
echo "  Profiles in complain mode: $COMPLAIN_COUNT"
echo "  Profiles still in enforce: $ENFORCE_COUNT (snap-confine, kernel-level)"
echo "  done."

echo "[3/5] Creating Slack reminder script at $SCRIPT_PATH..."
cat > "$SCRIPT_PATH" << 'REMIND_SCRIPT'
#!/bin/bash
WEBHOOK_URL="__WEBHOOK_URL__"
HOSTNAME=$(hostname)
PROFILES_COUNT=$(aa-status 2>/dev/null | grep -c "complain" || echo "?")
LOG_VIOLATIONS=$(journalctl -t kernel --since "__LEARNING_DAYS__ days ago" 2>/dev/null | grep -c 'apparmor="ALLOWED"' || echo "0")

curl -s -X POST "$WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d @- <<EOFMSG
{
  "username": "AppArmor Bot",
  "icon_emoji": ":shield:",
  "text": ":shield: *AppArmor: __LEARNING_DAYS__-day learning period is complete*\n\n*Host:* \`${HOSTNAME}\`\n*Profiles in complain mode:* ${PROFILES_COUNT}\n*Logged allowed violations:* ${LOG_VIOLATIONS}\n\n---\n\n*What happened over the last __LEARNING_DAYS__ days?*\nAll AppArmor profiles were in *complain (learning) mode*. This means AppArmor did NOT block anything, but it logged every application behavior that would otherwise be denied. This helps learn what normal system operation looks like.\n\n*What to do now:*\n\n1. Review learned rules interactively:\n\`\`\`\nsudo aa-logprof\n\`\`\`\nThis shows each violation and asks whether to Allow, Deny, or ignore it.\n\n2. Once done reviewing, switch all profiles to enforce mode:\n\`\`\`\nsudo aa-enforce /etc/apparmor.d/*\n\`\`\`\n\n3. Verify status:\n\`\`\`\nsudo aa-status | head -20\n\`\`\`\n\n*Not ready yet?* No rush. Profiles stay in complain mode until you manually switch them. Nothing will break.\n\n---\n_This reminder was sent automatically by a systemd timer. The timer is now disabled._"
}
EOFMSG

logger "AppArmor: learning period reminder sent to Slack."
systemctl disable apparmor-enforce.timer 2>/dev/null || true
REMIND_SCRIPT

sed -i "s|__WEBHOOK_URL__|${WEBHOOK_URL}|g" "$SCRIPT_PATH"
sed -i "s|__LEARNING_DAYS__|${LEARNING_DAYS}|g" "$SCRIPT_PATH"
chmod +x "$SCRIPT_PATH"
echo "  done."

echo "[4/5] Creating systemd timer (fires in ${LEARNING_DAYS} days)..."
cat > "$SERVICE_PATH" << EOF
[Unit]
Description=AppArmor learning reminder (Slack notification)

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
EOF

cat > "$TIMER_PATH" << EOF
[Unit]
Description=Trigger AppArmor reminder after ${LEARNING_DAYS} days

[Timer]
OnActiveSec=${LEARNING_DAYS}d
AccuracySec=1h

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now apparmor-enforce.timer
echo "  done."

echo "[5/5] Sending test message to Slack..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d "{\"username\": \"AppArmor Bot\", \"icon_emoji\": \":shield:\", \"text\": \":white_check_mark: *AppArmor learning mode activated on \`$(hostname)\`.*\nReminder in ${LEARNING_DAYS} days.\"}")

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "  webhook test: OK (HTTP $HTTP_CODE)"
else
    echo "  webhook test: FAILED (HTTP $HTTP_CODE) -- check the URL"
fi
echo "  done."

echo ""
echo "=== AppArmor setup complete ==="
echo ""
echo "Timer fires on: $(date -d "+${LEARNING_DAYS} days" '+%A %Y-%m-%d %H:%M')"
echo ""
echo "After receiving the Slack reminder, run:"
echo "  sudo aa-logprof          # review learned rules interactively"
echo "  sudo aa-enforce /etc/apparmor.d/*   # switch to enforce mode"
echo "  sudo aa-status | head -20           # verify"
