#!/bin/bash
set -euo pipefail

# AppArmor Learning Mode Setup
# Author: Dusan Panic <dpanic@gmail.com>
# Installs apparmor-utils, switches all profiles to complain (learning) mode,
# and installs a systemd timer that fires after LEARNING_DAYS to enforce (or
# remind). Sends Slack/Rocket.Chat-compatible webhook notifications.
#
# Docker safety (why this differs from a naive "complain everything"):
#   Some Ubuntu builds ship an AppArmor `runc`/`crun` profile that breaks
#   `docker run` (runc memfd re-exec -> "fork/exec /proc/self/fd/N: permission
#   denied") the moment the profile is LOADED -- even in COMPLAIN mode, where
#   the kernel logs every op as ALLOWED yet container creation still fails.
#   complain mode does NOT fix this; the profile must be UNLOADED/disabled.
#   So after switching to complain we run a docker smoke-test and, if container
#   creation is broken, DISABLE the container-runtime profiles (unload + symlink
#   into /etc/apparmor.d/disable/) and re-test. Those profiles are then also
#   excluded from the enforce step. Set DOCKER_SAFE=0 (or --no-docker-safe) to
#   skip this behaviour.
#
# This installer intentionally does NOT install apparmor-profiles /
# apparmor-profiles-extra: on recent Ubuntu (e.g. 26.04 "resolute" beta) that
# bundle is exactly what regresses docker, and the base apparmor package already
# ships ample profiles to learn from.
#
# Usage:
#   sudo ./setup.sh [--auto-enforce] [--no-docker-safe] <webhook-url>
#   sudo ./setup.sh --update
#   sudo ./setup.sh --uninstall
#
# Example:
#   sudo ./setup.sh --auto-enforce https://chat.example.tld/hooks/XXXX

if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root (sudo)."
    exit 1
fi

# Parse flags and positional args
WEBHOOK_URL=""
MODE=""
AUTO_ENFORCE=0
DOCKER_SAFE="${DOCKER_SAFE:-1}"
for arg in "$@"; do
    case "$arg" in
        --uninstall)      MODE="uninstall" ;;
        --update)         MODE="update" ;;
        --auto-enforce)   AUTO_ENFORCE=1 ;;
        --no-docker-safe) DOCKER_SAFE=0 ;;
        *)                WEBHOOK_URL="$arg" ;;
    esac
done

LEARNING_DAYS=30
SCRIPT_PATH="/usr/local/bin/apparmor-remind.sh"
SERVICE_PATH="/etc/systemd/system/apparmor-enforce.service"
TIMER_PATH="/etc/systemd/system/apparmor-enforce.timer"
DISABLE_DIR="/etc/apparmor.d/disable"

# Container-runtime profiles that, on some Ubuntu builds, break docker when
# loaded (even in complain mode). The docker smoke-test below disables these
# automatically when needed, and they are always excluded from enforce.
RUNTIME_PROFILES=(runc crun)

# ── Helpers ──────────────────────────────────────────────────────────────────

# Pick a smoke-test image: prefer a tiny local one, else any local image.
_smoke_image() {
    docker image inspect hello-world >/dev/null 2>&1 && { echo "hello-world"; return; }
    docker images -q 2>/dev/null | head -1
}

# Return 0 if `docker run` can create a container, 1 if container creation is
# broken by AppArmor. If docker is absent/down or no image exists, assume OK
# (nothing we can or should test).
docker_can_run() {
    command -v docker >/dev/null 2>&1 || return 0
    docker info >/dev/null 2>&1 || return 0
    local img out
    img="$(_smoke_image)"
    [[ -z "$img" ]] && return 0
    out=$(timeout 60 docker run --rm --entrypoint true "$img" 2>&1) && return 0
    # rc!=0: only treat as broken if it's the AppArmor/runc signature. Other
    # failures (e.g. image has no `true`) still mean runc init succeeded -> OK.
    echo "$out" | grep -qE 'fork/exec /proc/self/fd|unable to start container process' && return 1
    return 0
}

# Unload + persistently disable the container-runtime profiles.
disable_runtime_profiles() {
    mkdir -p "$DISABLE_DIR"
    local p
    for p in "${RUNTIME_PROFILES[@]}"; do
        [[ -f "/etc/apparmor.d/$p" ]] || continue
        apparmor_parser -R "/etc/apparmor.d/$p" 2>/dev/null || true
        ln -sf "/etc/apparmor.d/$p" "$DISABLE_DIR/$p"
        echo "  disabled (unloaded) container-runtime profile: $p"
    done
}

# Echo (one per line) the profile files to enforce: every top-level profile in
# /etc/apparmor.d/ EXCEPT the runtime profiles and anything already disabled.
enforce_list() {
    local f base e skip
    for f in /etc/apparmor.d/*; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        skip=0
        for e in "${RUNTIME_PROFILES[@]}"; do [[ "$base" == "$e" ]] && skip=1; done
        [[ -e "$DISABLE_DIR/$base" ]] && skip=1
        [[ $skip -eq 1 ]] && continue
        printf '%s\n' "$f"
    done
}

# ── Uninstall ────────────────────────────────────────────────────────────────

if [[ "$MODE" == "uninstall" ]]; then
    echo "=== AppArmor -- Revert ==="
    echo ""
    echo "[1/3] Switching profiles back to enforce (container-runtime profiles stay disabled)..."
    mapfile -t _files < <(enforce_list)
    if [[ ${#_files[@]} -gt 0 ]]; then
        aa-enforce "${_files[@]}" 2>&1 | tail -5 || true
    fi
    echo "  done. ${RUNTIME_PROFILES[*]} left disabled so docker keeps working;"
    echo "  re-enable manually (rm $DISABLE_DIR/<name>) only on a fixed AppArmor build."

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
    echo "Error: webhook URL is required."
    echo "Usage: sudo $0 [--auto-enforce] [--no-docker-safe] <webhook-url>"
    exit 1
fi

# Validate the webhook URL strictly. This string is later interpolated into a
# sed substitution that writes a root-executed script and into a curl JSON body,
# so any control byte, quote, or shell metacharacter could escape its context
# and become code. Restrict to the unreserved + reserved URL character classes
# from RFC 3986; reject anything else.
if [[ ! "$WEBHOOK_URL" =~ ^https://[A-Za-z0-9._~:/?\#%@\&=+-]+$ ]]; then
    echo "Error: webhook URL contains characters that are not safe to embed in a script."
    echo "       Allowed: A-Z a-z 0-9 . _ ~ : / ? # % @ & = + -"
    echo "       Must start with https://"
    exit 1
fi

echo "=== AppArmor Learning Mode Setup ==="
echo "  Learning period: ${LEARNING_DAYS} days"
if [[ "$AUTO_ENFORCE" == "1" ]]; then
    echo "  Mode: AUTO-ENFORCE (profiles switch to enforce after ${LEARNING_DAYS} days, except ${RUNTIME_PROFILES[*]})"
else
    echo "  Mode: REMINDER ONLY (manual enforce after ${LEARNING_DAYS} days)"
fi
echo "  Docker-safe: $([[ "$DOCKER_SAFE" == "1" ]] && echo on || echo off)"
echo "  Webhook: ${WEBHOOK_URL:0:50}..."
echo ""

echo "[1/5] Installing apparmor-utils..."
# Deliberately NOT installing apparmor-profiles / apparmor-profiles-extra -- see
# the header note. The base apparmor package already provides the profiles.
apt-get install -y apparmor-utils
echo "  done."

echo "[2/5] Switching all profiles to complain (learning) mode..."
# Don't let a single profile's non-zero exit abort the whole setup (pipefail
# would otherwise propagate aa-complain's status through `| tail`). Capture/warn.
set +e
aa-complain /etc/apparmor.d/* 2>&1 | tail -5
_aa_rc=${PIPESTATUS[0]}
set -e
[[ $_aa_rc -ne 0 ]] && echo "  WARNING: aa-complain exited $_aa_rc -- some profiles may not have switched; continuing." >&2

if [[ "$DOCKER_SAFE" == "1" ]]; then
    echo "  docker-safe: testing container creation under complain mode..."
    if docker_can_run; then
        echo "  docker OK under complain -- no runtime profiles need disabling."
    else
        echo "  docker BROKEN under complain -- complain is not enough on this AppArmor build."
        echo "  Disabling container-runtime profiles:"
        disable_runtime_profiles
        if docker_can_run; then
            echo "  docker OK after disabling ${RUNTIME_PROFILES[*]}."
        else
            echo "  WARNING: docker still broken after disabling ${RUNTIME_PROFILES[*]} -- investigate manually." >&2
        fi
    fi
fi
echo ""
# apparmor 4.x/5.x rewrote aa-status; its listing no longer appends "(complain)"
# per profile, so `grep -c complain` always returns 1. Use the machine-readable
# count flags instead (supported on both the legacy and the new binary).
COMPLAIN_COUNT=$(aa-status --count --complaining 2>/dev/null || echo "?")
ENFORCE_COUNT=$(aa-status --count --enforced 2>/dev/null || echo "?")
echo "  Profiles in complain mode: $COMPLAIN_COUNT"
echo "  Profiles still in enforce: $ENFORCE_COUNT"
echo "  done."

echo "[3/5] Creating reminder/enforce script at $SCRIPT_PATH..."
cat > "$SCRIPT_PATH" << 'REMIND_SCRIPT'
#!/bin/bash
# Generated by os-kickstart apparmor setup.sh -- fired once by a systemd timer.
WEBHOOK_URL="__WEBHOOK_URL__"
AUTO_ENFORCE="__AUTO_ENFORCE__"
LEARNING_DAYS="__LEARNING_DAYS__"
DISABLE_DIR="/etc/apparmor.d/disable"
RUNTIME_PROFILES=(__RUNTIME_PROFILES__)
HOSTNAME=$(hostname)

# True if a profile must be excluded from enforce (runtime profile or disabled).
excluded() {
    local base="$1" e
    for e in "${RUNTIME_PROFILES[@]}"; do [ "$base" = "$e" ] && return 0; done
    [ -e "$DISABLE_DIR/$base" ] && return 0
    return 1
}

# 0 if docker can create a container, 1 if AppArmor breaks it.
docker_ok() {
    command -v docker >/dev/null 2>&1 || return 0
    docker info >/dev/null 2>&1 || return 0
    local img out
    img=$(docker image inspect hello-world >/dev/null 2>&1 && echo hello-world || docker images -q | head -1)
    [ -z "$img" ] && return 0
    out=$(timeout 60 docker run --rm --entrypoint true "$img" 2>&1) && return 0
    echo "$out" | grep -qE 'fork/exec /proc/self/fd|unable to start container process' && return 1
    return 0
}

if [ "$AUTO_ENFORCE" = "1" ]; then
    to_enforce=()
    for f in /etc/apparmor.d/*; do
        [ -f "$f" ] || continue
        excluded "$(basename "$f")" && continue
        to_enforce+=("$f")
    done
    aa-enforce "${to_enforce[@]}" >/dev/null 2>&1 || true
    # Belt-and-suspenders: keep the runtime profiles unloaded.
    for p in "${RUNTIME_PROFILES[@]}"; do apparmor_parser -R "/etc/apparmor.d/$p" 2>/dev/null || true; done
    logger "AppArmor: auto-enforced (excluding ${RUNTIME_PROFILES[*]}) after ${LEARNING_DAYS}-day learning period"

    ENFORCED=$(aa-status --count --enforced 2>/dev/null || echo "?")
    if docker_ok; then
        DOCKER_LINE="\n*Docker smoke-test:* :white_check_mark: PASS"
    else
        DOCKER_LINE="\n*Docker smoke-test:* :rotating_light: FAIL -- revert: \`sudo aa-complain /etc/apparmor.d/*\`"
    fi
    MESSAGE_TEXT=":shield: *AppArmor: ${LEARNING_DAYS}-day learning complete -- AUTO-ENFORCED on \`${HOSTNAME}\`*\n\n*Profiles enforced:* ${ENFORCED}\n*Kept disabled (would break docker):* ${RUNTIME_PROFILES[*]}${DOCKER_LINE}\n\nVerify:\n\`\`\`\nsudo aa-status | head -20\n\`\`\`\nIf something breaks, revert with:\n\`\`\`\nsudo aa-complain /etc/apparmor.d/*\n\`\`\`"
else
    PROFILES_COUNT=$(aa-status --count --complaining 2>/dev/null || echo "?")
    LOG_VIOLATIONS=$(journalctl -t kernel --since "__LEARNING_DAYS__ days ago" 2>/dev/null | grep -c 'apparmor="ALLOWED"' || echo "0")
    MESSAGE_TEXT=":shield: *AppArmor: ${LEARNING_DAYS}-day learning period is complete*\n\n*Host:* \`${HOSTNAME}\`\n*Profiles in complain mode:* ${PROFILES_COUNT}\n*Logged allowed violations:* ${LOG_VIOLATIONS}\n\nReview learned rules:\n\`\`\`\nsudo aa-logprof\n\`\`\`\nThen enforce everything EXCEPT the disabled container-runtime profiles (they break docker on this build):\n\`\`\`\nfor f in /etc/apparmor.d/*; do [ -f \"\$f\" ] && [ ! -e \"\$DISABLE_DIR/\$(basename \"\$f\")\" ] && sudo aa-enforce \"\$f\"; done\n\`\`\`\nVerify:\n\`\`\`\nsudo aa-status | head -20\n\`\`\`"
fi

curl -s -X POST "$WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d @- <<EOFMSG
{
  "username": "AppArmor Bot",
  "icon_emoji": ":shield:",
  "text": "${MESSAGE_TEXT}\n\n---\n_Sent automatically by a systemd timer. The timer is now disabled._"
}
EOFMSG

logger "AppArmor: learning period notification sent."
systemctl disable apparmor-enforce.timer 2>/dev/null
REMIND_SCRIPT

sed -i "s|__WEBHOOK_URL__|${WEBHOOK_URL}|g" "$SCRIPT_PATH"
sed -i "s|__LEARNING_DAYS__|${LEARNING_DAYS}|g" "$SCRIPT_PATH"
sed -i "s|__AUTO_ENFORCE__|${AUTO_ENFORCE}|g" "$SCRIPT_PATH"
sed -i "s|__RUNTIME_PROFILES__|${RUNTIME_PROFILES[*]}|g" "$SCRIPT_PATH"
chmod +x "$SCRIPT_PATH"
echo "  done."

echo "[4/5] Creating systemd timer (fires in ${LEARNING_DAYS} days)..."
cat > "$SERVICE_PATH" << EOF
[Unit]
Description=AppArmor learning reminder/enforce (webhook notification)
After=docker.service apparmor.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
EOF

cat > "$TIMER_PATH" << EOF
[Unit]
Description=Trigger AppArmor reminder/enforce after ${LEARNING_DAYS} days

[Timer]
OnActiveSec=${LEARNING_DAYS}d
AccuracySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now apparmor-enforce.timer
echo "  done."

echo "[5/5] Sending test message..."
if [[ "$AUTO_ENFORCE" == "1" ]]; then
    TEST_TEXT=":white_check_mark: *AppArmor learning mode activated on \`$(hostname)\`.*\n*AUTO-ENFORCE* in ${LEARNING_DAYS} days (except ${RUNTIME_PROFILES[*]})."
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
if ls "$DISABLE_DIR"/* >/dev/null 2>&1; then
    echo "Disabled (kept out of complain/enforce to protect docker): $(basename -a "$DISABLE_DIR"/* | tr '\n' ' ')"
fi
echo ""
if [[ "$AUTO_ENFORCE" == "1" ]]; then
    echo "Mode: AUTO-ENFORCE (excluding ${RUNTIME_PROFILES[*]})"
    echo "  To cancel: sudo systemctl disable --now apparmor-enforce.timer"
else
    echo "Mode: REMINDER (manual enforce)"
    echo "  After the reminder: sudo aa-logprof ; then enforce (the script's message has the exact one-liner)."
fi
