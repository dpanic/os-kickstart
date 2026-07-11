#!/bin/bash
set -euo pipefail

# USB Monitor runtime -- invoked by udev on every USB device-add event.
# Author: Dusan Panic <dpanic@gmail.com>
#
# Installed to /usr/local/bin/usb-monitor-alert.sh by monitor.sh (installer).
# Reads device properties from udev-exported env vars (ID_VENDOR_ID, etc.),
# checks against allowlist, and POSTs a webhook alert for unknown devices.
#
# Config lives in /var/lib/usb-monitor/:
#   webhook-url   -- notification endpoint
#   allow         -- VID:PID allowlist (one per line, lowercase hex)
#   events.log    -- TSV append-only event log; consumed by digest.sh and
#                    used here for burst rate limiting

# ── Detach from udev's 3s RUN+= timeout ─────────────────────────────────────
# udev invokes us synchronously and kills slow scripts. Re-exec ourselves
# into a transient systemd unit on first entry so the webhook curl cannot
# stall device enumeration.

if [[ -z "${USB_MONITOR_DETACHED:-}" ]]; then
    exec /usr/bin/systemd-run --no-block --quiet --collect \
        --unit="usb-monitor-alert-$$" \
        --setenv=USB_MONITOR_DETACHED=1 \
        --setenv=ACTION="${ACTION:-}" \
        --setenv=SUBSYSTEM="${SUBSYSTEM:-}" \
        --setenv=DEVTYPE="${DEVTYPE:-}" \
        --setenv=ID_VENDOR_ID="${ID_VENDOR_ID:-}" \
        --setenv=ID_MODEL_ID="${ID_MODEL_ID:-}" \
        --setenv=ID_VENDOR="${ID_VENDOR:-}" \
        --setenv=ID_MODEL="${ID_MODEL:-}" \
        --setenv=ID_VENDOR_FROM_DATABASE="${ID_VENDOR_FROM_DATABASE:-}" \
        --setenv=ID_MODEL_FROM_DATABASE="${ID_MODEL_FROM_DATABASE:-}" \
        --setenv=ID_SERIAL="${ID_SERIAL:-}" \
        --setenv=ID_SERIAL_SHORT="${ID_SERIAL_SHORT:-}" \
        --setenv=ID_USB_INTERFACES="${ID_USB_INTERFACES:-}" \
        --setenv=BUSNUM="${BUSNUM:-}" \
        --setenv=DEVNUM="${DEVNUM:-}" \
        "$0"
fi

# ── Sanity checks ───────────────────────────────────────────────────────────

[[ "${ACTION:-}" == "add" ]] || exit 0
[[ "${SUBSYSTEM:-}" == "usb" ]] || exit 0
[[ "${DEVTYPE:-}" == "usb_device" ]] || exit 0
[[ -n "${ID_VENDOR_ID:-}" && -n "${ID_MODEL_ID:-}" ]] || exit 0

STATE_DIR="/var/lib/usb-monitor"
ALLOW_FILE="$STATE_DIR/allow"
EVENTS_LOG="$STATE_DIR/events.log"
HOSTNAME=$(hostname)
BURST_WINDOW_SECONDS=300
BURST_MAX_ALERTS=3

WEBHOOK_URL="$(cat "$STATE_DIR/webhook-url" 2>/dev/null || true)"
if [[ -z "$WEBHOOK_URL" ]]; then
    logger -t usb-monitor "no webhook URL configured, skipping"
    exit 0
fi

VID="${ID_VENDOR_ID,,}"
PID="${ID_MODEL_ID,,}"

# Hard-validate the kernel-supplied identifiers. Real USB descriptors are
# exactly 4 lowercase hex digits; anything else is a hostile or corrupt
# device descriptor and gets dropped before any further string handling.
if ! [[ "$VID" =~ ^[0-9a-f]{4}$ ]] || ! [[ "$PID" =~ ^[0-9a-f]{4}$ ]]; then
    logger -t usb-monitor "malformed VID/PID rejected (lengths: ${#ID_VENDOR_ID}/${#ID_MODEL_ID})"
    exit 0
fi

KEY="${VID}:${PID}"

NOW=$(date +%s)
VENDOR_NAME="${ID_VENDOR_FROM_DATABASE:-${ID_VENDOR:-unknown}}"
MODEL_NAME="${ID_MODEL_FROM_DATABASE:-${ID_MODEL:-unknown}}"
SERIAL="${ID_SERIAL_SHORT:-${ID_SERIAL:-unknown}}"
INTERFACES="${ID_USB_INTERFACES:-unknown}"
BUS_PATH="${BUSNUM:-?}/${DEVNUM:-?}"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Defang attacker-controlled USB descriptor fields:
#   - strip all control characters (\x00-\x1f) so TSV/JSON/Markdown stay intact
#   - replace Markdown-table specials (|, backtick) so a hostile vendor name
#     cannot inject table rows or fenced-code escapes into the webhook
#   - cap length at 80 chars so a 64 KiB descriptor cannot bloat the payload
sanitize() {
    local s
    s=$(printf '%s' "$1" | tr -d '\000-\037')
    s="${s//|/_}"
    s="${s//\`/_}"
    s="${s:0:80}"
    printf '%s' "$s"
}
VENDOR_NAME=$(sanitize "$VENDOR_NAME")
MODEL_NAME=$(sanitize "$MODEL_NAME")
SERIAL=$(sanitize "$SERIAL")
INTERFACES=$(sanitize "$INTERFACES")

# Append-only event log. Used by digest.sh and for burst rate counting here.
# Format: epoch_ts \t key \t state \t vendor \t model \t serial \t interfaces
log_event() {
    local state="$1"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$NOW" "$KEY" "$state" "$VENDOR_NAME" "$MODEL_NAME" "$SERIAL" "$INTERFACES" \
        >> "$EVENTS_LOG"
}

# ── Allowlist check ─────────────────────────────────────────────────────────

if [[ -f "$ALLOW_FILE" ]]; then
    if grep -qxF -- "$KEY" <(grep -v '^[[:space:]]*#' "$ALLOW_FILE" | grep -v '^[[:space:]]*$'); then
        log_event "ALLOWED"
        logger -t usb-monitor "allowed ${KEY} (${VENDOR_NAME} ${MODEL_NAME})"
        exit 0
    fi
fi

# ── Burst rate limit ────────────────────────────────────────────────────────
# Allow up to BURST_MAX_ALERTS webhook posts in any BURST_WINDOW_SECONDS
# sliding window. Anything beyond is recorded as SUPPRESSED and surfaced
# via the hourly digest so nothing is missed.

WINDOW_START=$(( NOW - BURST_WINDOW_SECONDS ))
SENT_IN_WINDOW=0
if [[ -f "$EVENTS_LOG" ]]; then
    SENT_IN_WINDOW=$(awk -F'\t' -v cutoff="$WINDOW_START" \
        '$1 >= cutoff && $3 == "SENT" { count++ } END { print count+0 }' \
        "$EVENTS_LOG")
fi

if [[ $SENT_IN_WINDOW -ge $BURST_MAX_ALERTS ]]; then
    log_event "SUPPRESSED"
    logger -t usb-monitor "alert suppressed (burst limit ${SENT_IN_WINDOW}/${BURST_MAX_ALERTS} in ${BURST_WINDOW_SECONDS}s) for ${KEY}"
    exit 0
fi

# ── Build alert payload ─────────────────────────────────────────────────────

json_escape() {
    local raw="$1"
    raw="${raw//\\/\\\\}"
    raw="${raw//\"/\\\"}"
    raw="${raw//$'\b'/\\b}"
    raw="${raw//$'\f'/\\f}"
    raw="${raw//$'\r'/\\r}"
    raw="${raw//$'\t'/\\t}"
    raw="${raw//$'\n'/\\n}"
    printf '%s' "$raw"
}

msg=":electric_plug: **New USB device on \`${HOSTNAME}\`**"
msg+=$'\n\n'"| Field | Value |"
msg+=$'\n'"| --- | --- |"
msg+=$'\n'"| VID:PID | \`${KEY}\` |"
msg+=$'\n'"| Vendor | ${VENDOR_NAME} |"
msg+=$'\n'"| Model | ${MODEL_NAME} |"
msg+=$'\n'"| Serial | \`${SERIAL}\` |"
msg+=$'\n'"| Interfaces | \`${INTERFACES}\` |"
msg+=$'\n'"| Bus | ${BUS_PATH} |"
msg+=$'\n'"| Time | ${TIMESTAMP} |"
msg+=$'\n\n'"---"
msg+=$'\n'"**Trust this device?** Add to allowlist:"
msg+=$'\n'"\`\`\`"
msg+=$'\n'"echo '${KEY}' | sudo tee -a ${ALLOW_FILE}"
msg+=$'\n'"\`\`\`"

text=$(json_escape "$msg")
payload=$(printf '{"username":"USB Monitor","icon_emoji":":electric_plug:","text":"%s"}' "$text")

http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST "$WEBHOOK_URL" \
    -H 'Content-Type: application/json' \
    -d "$payload" || echo "000")

if [[ "$http_code" == "200" ]]; then
    log_event "SENT"
    logger -t usb-monitor "alert sent for ${KEY} (${VENDOR_NAME} ${MODEL_NAME}) HTTP ${http_code}"
else
    log_event "FAILED"
    logger -t usb-monitor "webhook POST failed for ${KEY} HTTP ${http_code}"
fi
