#!/bin/bash
set -euo pipefail

# AppArmor Learning Mode Setup
# Author: Dusan Panic <dpanic@gmail.com>
# Installs utils, switches all profiles to complain mode,
# sets up a systemd timer that fires after 7 days.
#
# By default the timer only sends a Slack reminder so you can run
# aa-logprof + aa-enforce manually. Pass --auto-enforce to make the
# timer also run `aa-enforce /etc/apparmor.d/*` automatically.
#
# Usage:
#   sudo ./apparmor-setup.sh [--auto-enforce] <slack-webhook-url>
#
# Example:
#   sudo ./apparmor-setup.sh https://hooks.slack.com/services/T.../B.../xxx
#   sudo ./apparmor-setup.sh --auto-enforce https://hooks.slack.com/...

if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root (sudo)."
    exit 1
fi

# Parse flags and positional args
WEBHOOK_URL=""
MODE=""
AUTO_ENFORCE=0
for arg in "$@"; do
    case "$arg" in
        --uninstall)    MODE="uninstall" ;;
        --update)       MODE="update" ;;
        --auto-enforce) AUTO_ENFORCE=1 ;;
        *)              WEBHOOK_URL="$arg" ;;
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
if [[ "$AUTO_ENFORCE" == "1" ]]; then
    echo "  Mode: AUTO-ENFORCE (profiles switch back to enforce after ${LEARNING_DAYS} days)"
else
    echo "  Mode: REMINDER ONLY (manual enforce after ${LEARNING_DAYS} days)"
fi
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
AUTO_ENFORCE="__AUTO_ENFORCE__"
HOSTNAME=$(hostname)
PROFILES_COUNT=$(aa-status 2>/dev/null | grep -c "complain" || echo "?")
LOG_VIOLATIONS=$(journalctl -t kernel --since "__LEARNING_DAYS__ days ago" 2>/dev/null | grep -c 'apparmor="ALLOWED"' || echo "0")

if [[ "$AUTO_ENFORCE" == "1" ]]; then
    aa-enforce /etc/apparmor.d/* 2>&1 | tail -5 || true
    logger "AppArmor: auto-enforced /etc/apparmor.d/* after __LEARNING_DAYS__-day learning period"
    POST_PROFILES_COUNT=$(aa-status 2>/dev/null | grep -c "enforce" || echo "?")
    MESSAGE_TEXT=":shield: *AppArmor: __LEARNING_DAYS__-day learning period complete -- AUTO-ENFORCED*\n\n*Host:* \`${HOSTNAME}\`\n*Profiles now in enforce mode:* ${POST_PROFILES_COUNT}\n*Logged allowed violations during learning:* ${LOG_VIOLATIONS}\n\n---\n\n*All profiles have been automatically switched to enforce mode.*\n\nVerify with:\n\`\`\`\nsudo aa-status | head -20\n\`\`\`\n\nIf something breaks, revert with:\n\`\`\`\nsudo aa-complain /etc/apparmor.d/*\n\`\`\`"
else
    MESSAGE_TEXT=":shield: *AppArmor: __LEARNING_DAYS__-day learning period is complete*\n\n*Host:* \`${HOSTNAME}\`\n*Profiles in complain mode:* ${PROFILES_COUNT}\n*Logged allowed violations:* ${LOG_VIOLATIONS}\n\n---\n\n*What happened over the last __LEARNING_DAYS__ days?*\nAll AppArmor profiles were in *complain (learning) mode*. This means AppArmor did NOT block anything, but it logged every application behavior that would otherwise be denied. This helps learn what normal system operation looks like.\n\n*What to do now:*\n\n1. Review learned rules interactively:\n\`\`\`\nsudo aa-logprof\n\`\`\`\nThis shows each violation and asks whether to Allow, Deny, or ignore it.\n\n2. Once done reviewing, switch all profiles to enforce mode:\n\`\`\`\nsudo aa-enforce /etc/apparmor.d/*\n\`\`\`\n\n3. Verify status:\n\`\`\`\nsudo aa-status | head -20\n\`\`\`\n\n*Not ready yet?* No rush. Profiles stay in complain mode until you manually switch them. Nothing will break."
fi

curl -s -X POST "$WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d @- <<EOFMSG
{
  "username": "AppArmor Bot",
  "icon_emoji": ":shield:",
  "text": "${MESSAGE_TEXT}\n\n---\n_This message was sent automatically by a systemd timer. The timer is now disabled._"
}
EOFMSG

logger "AppArmor: learning period notification sent to Slack."
systemctl disable apparmor-enforce.timer 2>/dev/null || true
REMIND_SCRIPT

sed -i "s|__WEBHOOK_URL__|${WEBHOOK_URL}|g" "$SCRIPT_PATH"
sed -i "s|__LEARNING_DAYS__|${LEARNING_DAYS}|g" "$SCRIPT_PATH"
sed -i "s|__AUTO_ENFORCE__|${AUTO_ENFORCE}|g" "$SCRIPT_PATH"
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
if [[ "$AUTO_ENFORCE" == "1" ]]; then
    TEST_TEXT=":white_check_mark: *AppArmor learning mode activated on \`$(hostname)\`.*\n*AUTO-ENFORCE enabled* -- profiles will switch back to enforce in ${LEARNING_DAYS} days."
else
    TEST_TEXT=":white_check_mark: *AppArmor learning mode activated on \`$(hostname)\`.*\nReminder in ${LEARNING_DAYS} days."
fi
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d "{\"username\": \"AppArmor Bot\", \"icon_emoji\": \":shield:\", \"text\": \"${TEST_TEXT}\"}")

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
if [[ "$AUTO_ENFORCE" == "1" ]]; then
    echo "Mode: AUTO-ENFORCE"
    echo "  Profiles will be automatically switched back to enforce mode."
    echo "  Optionally review learned rules before the timer fires:"
    echo "    sudo aa-logprof          # interactive review"
    echo "  To cancel auto-enforce:"
    echo "    sudo systemctl disable --now apparmor-enforce.timer"
else
    echo "Mode: REMINDER (manual enforce)"
    echo "  After receiving the Slack reminder, run:"
    echo "    sudo aa-logprof          # review learned rules interactively"
    echo "    sudo aa-enforce /etc/apparmor.d/*   # switch to enforce mode"
    echo "    sudo aa-status | head -20           # verify"
fi
