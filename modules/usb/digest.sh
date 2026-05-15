#!/bin/bash
set -euo pipefail

# USB Monitor digest -- runs hourly via systemd timer.
# Author: Dusan Panic <dpanic@gmail.com>
#
# Aggregates the last hour of unknown-USB events from
# /var/lib/usb-monitor/events.log and POSTs a single summary webhook so
# burst-rate-suppressed events still surface. Trims the log to keep it
# bounded.
#
# Installed to /usr/local/bin/usb-monitor-digest.sh by monitor.sh.

STATE_DIR="/var/lib/usb-monitor"
EVENTS_LOG="$STATE_DIR/events.log"
HOSTNAME=$(hostname)
WINDOW_SECONDS=3600   # last 1 hour
RETAIN_SECONDS=$(( 7 * 24 * 3600 ))  # trim events older than 7 days

WEBHOOK_URL="$(cat "$STATE_DIR/webhook-url" 2>/dev/null || true)"
if [[ -z "$WEBHOOK_URL" ]]; then
    logger -t usb-monitor "digest: no webhook URL configured, skipping"
    exit 0
fi

if [[ ! -f "$EVENTS_LOG" ]]; then
    logger -t usb-monitor "digest: no events.log yet, skipping"
    exit 0
fi

NOW=$(date +%s)
WINDOW_START=$(( NOW - WINDOW_SECONDS ))
WINDOW_LABEL=$(date -d "@${WINDOW_START}" '+%Y-%m-%d %H:%M')

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

# Defense in depth: events.log entries from older script versions may not
# have been sanitized at write time, so we re-sanitize on read before
# embedding into the webhook body.
sanitize() {
    local s
    s=$(printf '%s' "$1" | tr -d '\000-\037')
    s="${s//|/_}"
    s="${s//\`/_}"
    s="${s:0:80}"
    printf '%s' "$s"
}

# Aggregate events in the window: skip ALLOWED (digest only covers unknown
# devices); group by VID:PID; sum SENT/SUPPRESSED/FAILED counts; remember
# vendor/model and first/last timestamps.
SUMMARY=$(awk -F'\t' -v cutoff="$WINDOW_START" '
    BEGIN { rows = 0 }
    $1 >= cutoff && $3 != "ALLOWED" {
        key = $2
        if (!(key in seen)) {
            order[++rows] = key
            seen[key] = 1
            vendor[key] = $4
            model[key] = $5
            first[key] = $1
        }
        last[key] = $1
        if ($3 == "SENT") sent[key]++
        else if ($3 == "SUPPRESSED") suppressed[key]++
        else if ($3 == "FAILED") failed[key]++
        total[key]++
    }
    END {
        if (rows == 0) { print "EMPTY"; exit }
        printf "ROWS\t%d\n", rows
        for (i = 1; i <= rows; i++) {
            k = order[i]
            printf "ROW\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n", \
                k, vendor[k], model[k], total[k]+0, sent[k]+0, \
                suppressed[k]+0, failed[k]+0, first[k]+0, last[k]+0
        }
    }
' "$EVENTS_LOG")

if [[ "$SUMMARY" == "EMPTY" || -z "$SUMMARY" ]]; then
    logger -t usb-monitor "digest: no unknown USB events in the last ${WINDOW_SECONDS}s"
    # Still trim the log even when there's nothing to report.
    if [[ -f "$EVENTS_LOG" ]]; then
        TRIM_CUTOFF=$(( NOW - RETAIN_SECONDS ))
        awk -F'\t' -v cutoff="$TRIM_CUTOFF" '$1 >= cutoff' "$EVENTS_LOG" > "${EVENTS_LOG}.tmp" \
            && mv "${EVENTS_LOG}.tmp" "$EVENTS_LOG"
    fi
    exit 0
fi

ROW_COUNT=$(echo "$SUMMARY" | awk -F'\t' '$1 == "ROWS" { print $2 }')

msg=":bar_chart: **USB Monitor digest on \`${HOSTNAME}\`**"
msg+=$'\n\n'"Unknown USB devices seen in the last hour (since ${WINDOW_LABEL})."
msg+=$'\n\n'"| VID:PID | Vendor | Model | Total | Sent | Suppressed | Failed | First | Last |"
msg+=$'\n'"| --- | --- | --- | --- | --- | --- | --- | --- | --- |"

while IFS=$'\t' read -r tag key vendor model total sent suppressed failed first last; do
    [[ "$tag" != "ROW" ]] && continue
    # Drop rows whose key does not match the standard VID:PID hex shape.
    # Real USB descriptors always conform; anything else is corrupt or
    # adversarial and we refuse to render it into the webhook body.
    if ! [[ "$key" =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]]; then
        continue
    fi
    vendor=$(sanitize "$vendor")
    model=$(sanitize "$model")
    first_hm=$(date -d "@${first}" '+%H:%M:%S' 2>/dev/null || echo "?")
    last_hm=$(date -d "@${last}" '+%H:%M:%S' 2>/dev/null || echo "?")
    msg+=$'\n'"| \`${key}\` | ${vendor} | ${model} | ${total} | ${sent} | ${suppressed} | ${failed} | ${first_hm} | ${last_hm} |"
done <<< "$SUMMARY"

msg+=$'\n\n'"---"
msg+=$'\n'"Tail of raw log:"
msg+=$'\n'"\`\`\`"
msg+=$'\n'"sudo tail -n 50 ${EVENTS_LOG}"
msg+=$'\n'"\`\`\`"

text=$(json_escape "$msg")
payload=$(printf '{"username":"USB Monitor","icon_emoji":":bar_chart:","text":"%s"}' "$text")

http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 -X POST "$WEBHOOK_URL" \
    -H 'Content-Type: application/json' \
    -d "$payload" || echo "000")

if [[ "$http_code" == "200" ]]; then
    logger -t usb-monitor "digest: sent (${ROW_COUNT} distinct VID:PIDs) HTTP ${http_code}"
else
    logger -t usb-monitor "digest: webhook POST failed HTTP ${http_code}"
fi

# Trim events older than RETAIN_SECONDS so the log stays bounded.
TRIM_CUTOFF=$(( NOW - RETAIN_SECONDS ))
awk -F'\t' -v cutoff="$TRIM_CUTOFF" '$1 >= cutoff' "$EVENTS_LOG" > "${EVENTS_LOG}.tmp" \
    && mv "${EVENTS_LOG}.tmp" "$EVENTS_LOG"
