#!/bin/bash
set -euo pipefail

# AppArmor Continuous Monitor
# Author: Dusan Panic <dpanic@gmail.com>
# Installs a systemd timer that checks for AppArmor violations
# (DENIED/ALLOWED events, profile tampering, service health)
# and sends Slack alerts when security issues are detected.
#
# Usage:
#   sudo ./monitor.sh <slack-webhook-url>
#
# Example:
#   sudo ./monitor.sh https://hooks.slack.com/services/T.../B.../xxx

if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root (sudo)."
    exit 1
fi

MONITOR_SCRIPT="/usr/local/bin/apparmor-monitor.sh"
STATE_DIR="/var/lib/apparmor-monitor"
SERVICE_PATH="/etc/systemd/system/apparmor-monitor.service"
TIMER_PATH="/etc/systemd/system/apparmor-monitor.timer"
CHECK_INTERVAL="15min"

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

# Handle --uninstall
if [[ "$MODE" == "uninstall" ]]; then
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

# On update without webhook arg, read it from the existing installed script
if [[ -z "$WEBHOOK_URL" && -f "$MONITOR_SCRIPT" ]]; then
    WEBHOOK_URL=$(grep -oP '^WEBHOOK_URL="\K[^"]+' "$MONITOR_SCRIPT" 2>/dev/null || true)
fi

if [[ -z "$WEBHOOK_URL" ]]; then
    echo "Error: Slack webhook URL is required."
    echo "Usage: sudo $0 <webhook-url>"
    exit 1
fi

echo "=== AppArmor Continuous Monitor Setup ==="
echo "  Check interval: every ${CHECK_INTERVAL}"
echo "  Webhook: ${WEBHOOK_URL:0:50}..."
echo ""

echo "[1/5] Creating state directory..."
mkdir -p "$STATE_DIR"

# Save current profile baseline for tamper detection
aa-status --json 2>/dev/null > "$STATE_DIR/baseline.json" || \
    aa-status 2>/dev/null > "$STATE_DIR/baseline.txt" || true

# Initialize last-check timestamp to now
date +%s > "$STATE_DIR/last-check"
echo "  done."

echo "[2/5] Creating monitoring script at $MONITOR_SCRIPT..."
cat > "$MONITOR_SCRIPT" << 'MONITOR_EOF'
#!/bin/bash
set -euo pipefail

WEBHOOK_URL="__WEBHOOK_URL__"
STATE_DIR="/var/lib/apparmor-monitor"
HOSTNAME=$(hostname)
RATE_LIMIT_SECONDS=300

last_check_ts() {
    if [[ -f "$STATE_DIR/last-check" ]]; then
        cat "$STATE_DIR/last-check"
    else
        date -d "15 minutes ago" +%s
    fi
}

last_alert_ts() {
    if [[ -f "$STATE_DIR/last-alert" ]]; then
        cat "$STATE_DIR/last-alert"
    else
        echo "0"
    fi
}

send_slack() {
    local text="$1"
    local now
    now=$(date +%s)
    local prev
    prev=$(last_alert_ts)
    local diff=$(( now - prev ))

    if [[ $diff -lt $RATE_LIMIT_SECONDS ]]; then
        logger "apparmor-monitor: alert suppressed (rate limit, ${diff}s < ${RATE_LIMIT_SECONDS}s)"
        return 0
    fi

    local payload
    payload=$(printf '{"username":"AppArmor Monitor","icon_emoji":":shield:","text":"%s"}' "$text")

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK_URL" \
        -H 'Content-Type: application/json' \
        -d "$payload")

    if [[ "$http_code" == "200" ]]; then
        echo "$now" > "$STATE_DIR/last-alert"
        logger "apparmor-monitor: alert sent to Slack (HTTP $http_code)"
    else
        logger "apparmor-monitor: Slack POST failed (HTTP $http_code)"
    fi
}

# Build a JSON-safe string: real newlines become \n, quotes and backslashes escaped.
# Uses printf %b to interpret escape sequences, then converts real newlines for JSON.
json_escape() {
    local raw="$1"
    raw="${raw//\\/\\\\}"
    raw="${raw//\"/\\\"}"
    raw="${raw//$'\n'/\\n}"
    printf '%s' "$raw"
}

# Build a markdown table row: | col1 | col2 | ...
table_row() { printf '| %s ' "$@"; printf '|'; }

# ── 1. Check AppArmor service health ────────────────────────────────────────

check_health() {
    if ! systemctl is-active apparmor &>/dev/null; then
        local msg
        msg=$(printf '%s\n\n%s\n%s\n\n%s\n%s\n%s' \
            ":red_circle: **AppArmor service is DOWN on \`${HOSTNAME}\`**" \
            "The AppArmor service is not running." \
            "**No profiles are being enforced.**" \
            "| Action | Command |" \
            "|:--|:--|" \
            "| Start service | \`sudo systemctl start apparmor\` |")
        send_slack "$(json_escape "$msg")"
        return 1
    fi
    return 0
}

# ── 2. Check journal for DENIED/ALLOWED events ─────────────────────────────

check_violations() {
    local since_ts
    since_ts=$(last_check_ts)
    local since_date
    since_date=$(date -d "@${since_ts}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')

    local denied_lines allowed_lines
    denied_lines=$(journalctl -t kernel --since "$since_date" --no-pager 2>/dev/null \
        | grep 'apparmor="DENIED"' || true)
    allowed_lines=$(journalctl -t kernel --since "$since_date" --no-pager 2>/dev/null \
        | grep 'apparmor="ALLOWED"' || true)

    local denied_count=0 allowed_count=0
    if [[ -n "$denied_lines" ]]; then
        denied_count=$(echo "$denied_lines" | wc -l)
    fi
    if [[ -n "$allowed_lines" ]]; then
        allowed_count=$(echo "$allowed_lines" | wc -l)
    fi

    if [[ $denied_count -eq 0 && $allowed_count -eq 0 ]]; then
        return 0
    fi

    local severity_icon=":warning:"
    local severity_label="WARNING"
    if [[ $denied_count -gt 0 ]]; then
        severity_icon=":rotating_light:"
        severity_label="CRITICAL"
    fi

    local msg
    msg=$(printf '%s **AppArmor %s on \`%s\`**\n' "$severity_icon" "$severity_label" "$HOSTNAME")
    msg+=$(printf '\n| Metric | Count |\n|:--|--:|\n| DENIED | **%d** |\n| ALLOWED | %d |\n| Period | since %s |\n' \
        "$denied_count" "$allowed_count" "$since_date")

    if [[ $denied_count -gt 0 ]]; then
        msg+=$(printf '\n**DENIED — top profiles:**\n\n| Profile | Count |\n|:--|--:|\n')
        msg+=$(echo "$denied_lines" \
            | grep -oP 'profile="\K[^"]+' \
            | sort | uniq -c | sort -rn | head -5 \
            | awk '{printf "| `%s` | %d |\n", $2, $1}')
        msg+=$'\n'
    fi

    if [[ $allowed_count -gt 0 ]]; then
        msg+=$(printf '\n**ALLOWED — top profiles:**\n\n| Profile | Count |\n|:--|--:|\n')
        msg+=$(echo "$allowed_lines" \
            | grep -oP 'profile="\K[^"]+' \
            | sort | uniq -c | sort -rn | head -5 \
            | awk '{printf "| `%s` | %d |\n", $2, $1}')
        msg+=$'\n'
    fi

    msg+=$(printf '\n---\n**Investigate:**\n```\nsudo journalctl -t kernel | grep apparmor | tail -30\nsudo aa-status\n```')

    send_slack "$(json_escape "$msg")"
}

# ── 3. Check for profile tampering ──────────────────────────────────────────

check_tamper() {
    local baseline_file=""
    if [[ -f "$STATE_DIR/baseline.json" ]]; then
        baseline_file="$STATE_DIR/baseline.json"
    elif [[ -f "$STATE_DIR/baseline.txt" ]]; then
        baseline_file="$STATE_DIR/baseline.txt"
    else
        return 0
    fi

    local current_enforce current_complain baseline_enforce baseline_complain

    if [[ "$baseline_file" == *.json ]] && command -v python3 &>/dev/null; then
        baseline_enforce=$(python3 -c "
import json, sys
d = json.load(open('$baseline_file'))
print(len(d.get('profiles', {}).get('enforce', {})))
" 2>/dev/null || echo "?")
        baseline_complain=$(python3 -c "
import json, sys
d = json.load(open('$baseline_file'))
print(len(d.get('profiles', {}).get('complain', {})))
" 2>/dev/null || echo "?")
    else
        baseline_enforce=$(grep -c "enforce" "$baseline_file" 2>/dev/null || echo "0")
        baseline_complain=$(grep -c "complain" "$baseline_file" 2>/dev/null || echo "0")
    fi

    current_enforce=$(aa-status 2>/dev/null | grep -c "enforce" || echo "0")
    current_complain=$(aa-status 2>/dev/null | grep -c "complain" || echo "0")

    if [[ "$current_enforce" == "$baseline_enforce" && "$current_complain" == "$baseline_complain" ]]; then
        return 0
    fi

    local enforce_diff=$(( current_enforce - baseline_enforce ))
    local complain_diff=$(( current_complain - baseline_complain ))

    local msg
    msg=$(printf ':warning: **AppArmor: profile state changed on `%s`**\n' "$HOSTNAME")
    msg+=$(printf '\n| Mode | Baseline | Current | Delta |\n|:--|--:|--:|--:|\n')
    msg+=$(printf '| Enforce | %s | %s | %+d |\n' "$baseline_enforce" "$current_enforce" "$enforce_diff")
    msg+=$(printf '| Complain | %s | %s | %+d |\n' "$baseline_complain" "$current_complain" "$complain_diff")
    msg+=$(printf '\n:warning: Profiles may have been switched or removed. **Possible tampering.**\n')
    msg+=$(printf '\n---\n**Investigate:**\n```\nsudo aa-status\n```')

    send_slack "$(json_escape "$msg")"

    # Update baseline after alerting to avoid repeat alerts
    aa-status --json 2>/dev/null > "$STATE_DIR/baseline.json" || \
        aa-status 2>/dev/null > "$STATE_DIR/baseline.txt" || true
}

# ── Main ────────────────────────────────────────────────────────────────────

check_health || true
check_violations
check_tamper

# Update last-check timestamp
date +%s > "$STATE_DIR/last-check"
logger "apparmor-monitor: check completed"
MONITOR_EOF

sed -i "s|__WEBHOOK_URL__|${WEBHOOK_URL}|g" "$MONITOR_SCRIPT"
chmod +x "$MONITOR_SCRIPT"
echo "  done."

echo "[3/5] Creating systemd service and timer..."
cat > "$SERVICE_PATH" << EOF
[Unit]
Description=AppArmor violation monitor (Slack alerts)
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

echo "[4/5] Sending test message to Slack..."
ACTIVATE_MSG=$(printf ':white_check_mark: **AppArmor monitor activated on `%s`**\n\n| Setting | Value |\n|:--|:--|\n| Interval | every %s |\n| Alerts | DENIED, ALLOWED, tamper, service down |\n| Rate limit | max 1 alert per 5 min |' \
  "$(hostname)" "${CHECK_INTERVAL}")
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
echo "Checks run every ${CHECK_INTERVAL}. Alerts sent to Slack when:"
echo "  - DENIED events detected (enforce mode blocks)"
echo "  - ALLOWED violations logged (complain mode would-be blocks)"
echo "  - Profile state changes (possible tampering)"
echo "  - AppArmor service goes down"
