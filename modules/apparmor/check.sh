#!/bin/bash
set -euo pipefail

# AppArmor runtime monitor -- called by systemd timer every 15 minutes.
# Checks for DENIED/ALLOWED events, profile tampering, and service health.
# Sends alerts via webhook when security issues are detected.
#
# Installed to /usr/local/bin/apparmor-monitor.sh by monitor.sh (installer).
# Config lives in /var/lib/apparmor-monitor/:
#   webhook-url       -- notification endpoint
#   ignore-profiles   -- profile names to exclude from DENIED alerts
#   baseline.json     -- profile snapshot for tamper detection
#   last-check        -- epoch timestamp of last run
#   last-alert        -- epoch timestamp of last alert (rate limiting)

STATE_DIR="/var/lib/apparmor-monitor"
IGNORE_FILE="$STATE_DIR/ignore-profiles"
HOSTNAME=$(hostname)
RATE_LIMIT_SECONDS=300

WEBHOOK_URL="$(cat "$STATE_DIR/webhook-url" 2>/dev/null || true)"
if [[ -z "$WEBHOOK_URL" ]]; then
    logger "apparmor-monitor: no webhook URL configured, skipping"
    exit 0
fi

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

send_webhook() {
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
        logger "apparmor-monitor: alert sent (HTTP $http_code)"
    else
        logger "apparmor-monitor: webhook POST failed (HTTP $http_code)"
    fi
}

json_escape() {
    local raw="$1"
    raw="${raw//\\/\\\\}"
    raw="${raw//\"/\\\"}"
    raw="${raw//$'\n'/\\n}"
    printf '%s' "$raw"
}

# head replacement that doesn't cause SIGPIPE in pipefail pipelines
first_n() { awk -v n="${1:-5}" 'NR<=n'; }

# Filter out ignored profile names from stdin (one name per line).
# Reads glob patterns from IGNORE_FILE; exact entries use string match,
# patterns with * use awk regex conversion.
filter_ignored_profiles() {
    [[ ! -f "$IGNORE_FILE" ]] && cat && return
    awk '
        NR==FNR {
            if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^#/) next
            pats[NR] = $0
            next
        }
        {
            # Drop synthetic null-transition stacks unconditionally.
            if (index($0, "//null-") > 0) next
            dominated = 0
            for (i in pats) {
                p = pats[i]
                if (index(p, "*") > 0) {
                    r = p; gsub(/\./, "\\.", r); gsub(/\*/, ".*", r)
                    if ($0 ~ "^"r"$") { dominated = 1; break }
                } else {
                    if ($0 == p) { dominated = 1; break }
                }
            }
            if (!dominated) print
        }
    ' "$IGNORE_FILE" -
}

# ── 1. Check AppArmor service health ────────────────────────────────────────

check_health() {
    if ! systemctl is-active apparmor &>/dev/null; then
        local msg
        msg=":red_circle: **AppArmor service is DOWN on \`${HOSTNAME}\`**"
        msg+=$'\n\n'"The AppArmor service is not running. **No profiles are being enforced.**"
        msg+=$'\n\n'"| Action | Command |"
        msg+=$'\n'"| --- | --- |"
        msg+=$'\n'"| Start service | \`sudo systemctl start apparmor\` |"
        msg+=$'\n'"| Check status | \`sudo systemctl status apparmor\` |"
        send_webhook "$(json_escape "$msg")"
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

    local denied_lines
    denied_lines=$(journalctl -t kernel --since "$since_date" --no-pager 2>/dev/null \
        | grep 'apparmor="DENIED"' || true)

    # Only count ALLOWED events -- don't store all lines (can be millions)
    local allowed_count=0
    allowed_count=$(journalctl -t kernel --since "$since_date" --no-pager 2>/dev/null \
        | grep -c 'apparmor="ALLOWED"' || true)

    # Drop synthetic null-transition stacks (parent//null-/path) — these are
    # complain-mode exec-chain artifacts, not real profile-attributable denials.
    if [[ -n "$denied_lines" ]]; then
        denied_lines=$(echo "$denied_lines" | grep -v 'profile="[^"]*//null-' || true)
    fi

    if [[ -n "$denied_lines" && -f "$IGNORE_FILE" ]]; then
        while IFS= read -r pattern; do
            [[ -z "$pattern" || "$pattern" == \#* ]] && continue
            if [[ "$pattern" == *\** ]]; then
                # Glob pattern: extract profile names, filter with fnmatch-style matching
                denied_lines=$(echo "$denied_lines" | awk -v pat="$pattern" '
                    {
                        match($0, /profile="[^"]+"/);
                        prof = substr($0, RSTART+9, RLENGTH-10);
                        # Convert glob to regex: escape dots, replace * with .*
                        gsub(/\./, "\\.", pat); gsub(/\*/, ".*", pat);
                        if (prof !~ "^"pat"$") print
                    }' || true)
            else
                denied_lines=$(echo "$denied_lines" | grep -v "profile=\"${pattern}\"" || true)
            fi
        done < "$IGNORE_FILE"
    fi

    local denied_count=0
    if [[ -n "$denied_lines" ]]; then
        denied_count=$(echo "$denied_lines" | wc -l)
    fi

    if [[ $denied_count -eq 0 ]]; then
        if [[ $allowed_count -gt 0 ]]; then
            logger "apparmor-monitor: ${allowed_count} ALLOWED events (complain mode), no alert needed"
        fi
        return 0
    fi

    local severity_icon=":rotating_light:"
    local severity_label="CRITICAL"

    local msg
    msg="${severity_icon} **AppArmor ${severity_label} on \`${HOSTNAME}\`**"
    msg+=$'\n\n'"| Metric | Count |"
    msg+=$'\n'"| --- | --- |"
    msg+=$'\n'"| DENIED | **${denied_count}** |"
    msg+=$'\n'"| ALLOWED | ${allowed_count} |"
    msg+=$'\n'"| Period | since ${since_date} |"

    msg+=$'\n\n'"**DENIED — top profiles:**"
    msg+=$'\n\n'"| Profile | Count |"
    msg+=$'\n'"| --- | --- |"
    msg+=$(echo "$denied_lines" \
        | grep -oP 'profile="\K[^"]+' \
        | sort | uniq -c | sort -rn | first_n 5 \
        | awk '{printf "\n| `%s` | %d |", $2, $1}')

    if [[ $allowed_count -gt 0 ]]; then
        msg+=$'\n\n'"**ALLOWED — top profiles (sampled):**"
        msg+=$'\n\n'"| Profile | Count |"
        msg+=$'\n'"| --- | --- |"
        msg+=$(journalctl -t kernel --since "$since_date" --no-pager 2>/dev/null \
            | grep 'apparmor="ALLOWED"' \
            | grep -oP 'profile="\K[^"]+' \
            | filter_ignored_profiles \
            | sort | uniq -c | sort -rn | first_n 5 \
            | awk '{printf "\n| `%s` | %d |", $2, $1}' || true)
    fi

    msg+=$'\n\n'"---"
    msg+=$'\n'"**Investigate:**"
    msg+=$'\n'"\`\`\`"
    msg+=$'\n'"sudo journalctl -t kernel | grep apparmor | tail -30"
    msg+=$'\n'"sudo aa-status"
    msg+=$'\n'"\`\`\`"

    send_webhook "$(json_escape "$msg")"
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

    if [[ "$baseline_file" != *.json ]] || ! command -v python3 &>/dev/null; then
        logger "apparmor-monitor: tamper check requires baseline.json + python3, skipping"
        return 0
    fi

    local current_json
    current_json=$(aa-status --json 2>/dev/null || true)
    if [[ -z "$current_json" ]]; then
        logger "apparmor-monitor: aa-status --json failed, skipping tamper check"
        return 0
    fi

    local diff_output
    diff_output=$(echo "$current_json" | python3 -c "
import json, sys, fnmatch

baseline = json.load(open('$baseline_file'))
current = json.load(sys.stdin)

# Load ignore patterns (supports glob wildcards)
ignore_patterns = []
try:
    with open('$IGNORE_FILE') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                ignore_patterns.append(line)
except FileNotFoundError:
    pass

def ignored(name):
    # Synthetic null-transition stacks (parent//null-/path) are runtime
    # artifacts of complain-mode exec chains, not real profile changes.
    # The //null- marker is reserved by the AppArmor kernel module.
    if '//null-' in name:
        return True
    return any(fnmatch.fnmatch(name, pat) for pat in ignore_patterns)

bp = baseline.get('profiles', {})
cp = current.get('profiles', {})

b_enforce = {k for k, v in bp.items() if v == 'enforce' and not ignored(k)}
b_complain = {k for k, v in bp.items() if v == 'complain' and not ignored(k)}
c_enforce = {k for k, v in cp.items() if v == 'enforce' and not ignored(k)}
c_complain = {k for k, v in cp.items() if v == 'complain' and not ignored(k)}

added_enforce = sorted(c_enforce - b_enforce)
removed_enforce = sorted(b_enforce - c_enforce)
added_complain = sorted(c_complain - b_complain)
removed_complain = sorted(b_complain - c_complain)

switched_to_complain = sorted(b_enforce & c_complain)
switched_to_enforce = sorted(b_complain & c_enforce)

changed = (added_enforce or removed_enforce or added_complain or removed_complain
           or switched_to_complain or switched_to_enforce)

print('CHANGED' if changed else 'OK')
print(f'{len(b_enforce)}|{len(c_enforce)}|{len(b_complain)}|{len(c_complain)}')

for p in added_enforce:
    print(f'+enforce|{p}')
for p in removed_enforce:
    print(f'-enforce|{p}')
for p in added_complain:
    print(f'+complain|{p}')
for p in removed_complain:
    print(f'-complain|{p}')
for p in switched_to_complain:
    print(f'enforce>complain|{p}')
for p in switched_to_enforce:
    print(f'complain>enforce|{p}')
" 2>/dev/null || echo "ERROR")

    if [[ "$diff_output" == "ERROR" ]]; then
        logger "apparmor-monitor: python3 profile diff failed"
        return 0
    fi

    local status_line counts_line
    status_line=$(echo "$diff_output" | first_n 1)
    counts_line=$(echo "$diff_output" | sed -n '2p')

    if [[ "$status_line" == "OK" ]]; then
        return 0
    fi

    IFS='|' read -r b_enf c_enf b_comp c_comp <<< "$counts_line"
    local enforce_diff=$(( c_enf - b_enf ))
    local complain_diff=$(( c_comp - b_comp ))

    local msg
    msg=":warning: **AppArmor: profile state changed on \`${HOSTNAME}\`**"
    msg+=$'\n\n'"| Mode | Baseline | Current | Delta |"
    msg+=$'\n'"| --- | --- | --- | --- |"
    msg+=$'\n'"| Enforce | ${b_enf} | ${c_enf} | ${enforce_diff} |"
    msg+=$'\n'"| Complain | ${b_comp} | ${c_comp} | ${complain_diff} |"

    local diff_lines
    diff_lines=$(echo "$diff_output" | tail -n +3)

    local section_added="" section_removed="" section_switched=""

    while IFS='|' read -r change_type profile_name; do
        [[ -z "$change_type" ]] && continue
        case "$change_type" in
            +enforce)
                section_added+=$'\n'"| \`${profile_name}\` | enforce | :new: added |"
                ;;
            +complain)
                section_added+=$'\n'"| \`${profile_name}\` | complain | :new: added |"
                ;;
            -enforce)
                section_removed+=$'\n'"| \`${profile_name}\` | enforce | :x: removed |"
                ;;
            -complain)
                section_removed+=$'\n'"| \`${profile_name}\` | complain | :x: removed |"
                ;;
            enforce\>complain)
                section_switched+=$'\n'"| \`${profile_name}\` | enforce :arrow_right: complain | :warning: weakened |"
                ;;
            complain\>enforce)
                section_switched+=$'\n'"| \`${profile_name}\` | complain :arrow_right: enforce | :white_check_mark: hardened |"
                ;;
        esac
    done <<< "$diff_lines"

    if [[ -n "$section_switched" ]]; then
        msg+=$'\n\n'":warning: **Mode switches** (possible tampering):"
        msg+=$'\n\n'"| Profile | Change | Status |"
        msg+=$'\n'"| --- | --- | --- |"
        msg+="$section_switched"
    fi

    if [[ -n "$section_added" ]]; then
        msg+=$'\n\n'":new: **New profiles:**"
        msg+=$'\n\n'"| Profile | Mode | Status |"
        msg+=$'\n'"| --- | --- | --- |"
        msg+="$section_added"
    fi

    if [[ -n "$section_removed" ]]; then
        msg+=$'\n\n'":x: **Removed profiles:**"
        msg+=$'\n\n'"| Profile | Mode | Status |"
        msg+=$'\n'"| --- | --- | --- |"
        msg+="$section_removed"
    fi

    msg+=$'\n\n'"---"
    msg+=$'\n'"**Investigate:**"
    msg+=$'\n'"\`\`\`"
    msg+=$'\n'"sudo aa-status"
    msg+=$'\n'"\`\`\`"

    send_webhook "$(json_escape "$msg")"

    echo "$current_json" > "$STATE_DIR/baseline.json"
}

# ── Main ────────────────────────────────────────────────────────────────────

check_health || true
check_violations
check_tamper

date +%s > "$STATE_DIR/last-check"
logger "apparmor-monitor: check completed"
