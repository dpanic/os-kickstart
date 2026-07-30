#!/bin/bash
set -uo pipefail

# AppArmor release watcher -- checked on a 30-day timer.
#
# Two things are watched, both of which have bitten this fleet:
#
#   1. A non-prerelease apparmor becoming available. The shipped
#      5.0.0~beta1 generates the allow-everything naming stubs with
#      flags=(complain) instead of flags=(default_allow), which makes every
#      file access of every confined app an audit record.
#   2. A package upgrade re-introducing complain on those stubs, silently
#      undoing the local fix. That regression costs ~2700 audit events/s,
#      saturates the audit backlog and parks tasks in audit_log_start, so
#      loadavg climbs past 40 while the CPU sits idle.

STATE_DIR="/var/lib/apparmor-version-watch"
ENV_FILE="/etc/apparmor-version-watch.env"
PKG="apparmor"
SERIES="${APPARMOR_WATCH_SERIES:-resolute}"
MADISON="https://people.canonical.com/~ubuntu-archive/madison.cgi"
STUB_MARKER="only exists to give the"

# shellcheck source=/dev/null
[[ -r "$ENV_FILE" ]] && . "$ENV_FILE"

mkdir -p "$STATE_DIR"
date +%s > "$STATE_DIR/last-check"

log() { logger -t apparmor-version-watch -- "$*"; echo "$*"; }

# ~alpha/~beta/~rc sort BELOW the plain release in dpkg version order, so a
# tilde segment is the reliable prerelease marker.
is_prerelease() {
    case "$1" in
        *~alpha*|*~beta*|*~rc*) return 0 ;;
    esac
    return 1
}

newer_than_installed() {
    dpkg --compare-versions "$1" gt "$INSTALLED" 2>/dev/null
}

INSTALLED="$(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null)"
if [[ -z "$INSTALLED" ]]; then
    log "apparmor not installed, nothing to watch"
    exit 0
fi

# ── Gather candidate versions ───────────────────────────────────────────────
# Upstream archive is the release truth; apt-cache is what this box could
# actually install right now (apt-daily refreshes the index daily).

declare -A FOUND_IN

upstream="$(curl -sS -m 30 \
    "${MADISON}?package=${PKG}&text=on&s=${SERIES},${SERIES}-updates,${SERIES}-security,${SERIES}-proposed" \
    2>/dev/null)"

while IFS='|' read -r _pkg ver pocket _rest; do
    ver="$(echo "$ver" | tr -d ' ')"
    pocket="$(echo "$pocket" | tr -d ' ')"
    [[ -z "$ver" || -z "$pocket" ]] && continue
    FOUND_IN["$ver"]="${FOUND_IN[$ver]:+${FOUND_IN[$ver]},}${pocket}"
done <<< "$upstream"

while read -r _pkg ver _rest; do
    [[ -z "$ver" ]] && continue
    FOUND_IN["$ver"]="${FOUND_IN[$ver]:+${FOUND_IN[$ver]},}local-mirror"
done <<< "$(apt-cache madison "$PKG" 2>/dev/null | tr -s ' ' | tr '|' ' ')"

# ── Classify ────────────────────────────────────────────────────────────────

installable=""; staged=""
for ver in "${!FOUND_IN[@]}"; do
    is_prerelease "$ver" && continue
    newer_than_installed "$ver" || continue
    # Match whole pocket tokens: a bare "resolute" is installable, but
    # "resolute-proposed" is only staged, and substring matching confuses the two.
    pockets=",${FOUND_IN[$ver]},"
    if [[ "$pockets" == *,local-mirror,* || "$pockets" == *,"${SERIES}",* \
       || "$pockets" == *,"${SERIES}-updates",* || "$pockets" == *,"${SERIES}-security",* ]]; then
        installable+="  ${ver}  [${FOUND_IN[$ver]}]"$'\n'
    else
        staged+="  ${ver}  [${FOUND_IN[$ver]}]"$'\n'
    fi
done

# ── Guard: did an upgrade put the naming stubs back into complain? ──────────

regressed="$(grep -rlE 'flags=\([^)]*complain' /etc/apparmor.d/ 2>/dev/null \
    | xargs -r grep -l "$STUB_MARKER" 2>/dev/null | wc -l)"

# ── Notify ──────────────────────────────────────────────────────────────────

notify() {
    local title="$1" prio="$2" tags="$3" body="$4"
    if [[ -z "${NTFY_URL:-}" || -z "${NTFY_TOPIC:-}" || -z "${NTFY_AUTH:-}" ]]; then
        log "ntfy not configured in $ENV_FILE, alert suppressed: $title"
        return 1
    fi
    local code
    code="$(curl -sS -m 25 -o /dev/null -w '%{http_code}' \
        -u "$NTFY_AUTH" \
        -H "Title: ${title}" -H "Priority: ${prio}" -H "Tags: ${tags}" \
        -d "$body" "${NTFY_URL}/${NTFY_TOPIC}")"
    [[ "$code" == "200" ]] && log "ntfy sent ($title)" || log "ntfy FAILED http=$code ($title)"
}

# Fire only when the finding changed since last time. Both sides go through
# command substitution because it strips trailing newlines -- comparing a raw
# "$payload" against "$(cat state)" never matches, and every run re-alerts.
alert_once() {
    local key="$1" payload="$2" title="$3" prio="$4" tags="$5" body="$6"
    local file="$STATE_DIR/last-alerted-$key" norm prev
    norm="$(printf '%s' "$payload")"
    prev="$(cat "$file" 2>/dev/null || true)"
    if [[ "$prev" == "$norm" ]]; then
        log "$key unchanged since last alert, staying quiet"
        return 1
    fi
    # Persist only on a delivered alert. Marking it sent after a failed push
    # would burn the finding and go quiet for another whole 30-day cycle.
    if notify "$title" "$prio" "$tags" "$body"; then
        printf '%s' "$norm" > "$file"
        return 0
    fi
    log "$key alert undelivered, state not persisted -- will retry next cycle"
    return 1
}

alerted=0

if [[ -n "$regressed" && "$regressed" -gt 0 ]]; then
    notify "AppArmor: complain mode is back on $(hostname)" urgent "rotating_light,shield" \
"$regressed allow-everything naming stub(s) are in complain mode again.

Every file access of every confined app becomes an audit record:
~2700 events/s, audit backlog saturates, tasks park in audit_log_start,
loadavg climbs while CPU stays idle.

Re-apply: flip flags=(complain) -> flags=(default_allow) on stubs
carrying the marker \"$STUB_MARKER\", then: systemctl reload apparmor

Installed: $INSTALLED"
    alerted=1
fi

if [[ -n "$installable" ]]; then
    alert_once installable "$installable" \
        "AppArmor non-beta INSTALLABLE on $(hostname)" high "tada,package" \
"A non-prerelease apparmor is available to install.

Installed: $INSTALLED (prerelease)
Available:
${installable}
Upgrade, then verify the naming stubs use flags=(default_allow),
not flags=(complain). Keep /etc/apt/preferences.d/no-apparmor-profiles.pref
intact -- it blocks the apparmor-profiles bundle that breaks docker/runc." \
        && alerted=1
fi

if [[ -n "$staged" ]]; then
    alert_once staged "$staged" \
        "AppArmor non-beta staged in -proposed" default "package,eyes" \
"A non-prerelease apparmor exists upstream but is not installable here yet
(not in the LAN mirror, and -proposed is a staging pocket).

Installed: $INSTALLED (prerelease)
Staged:
${staged}
No action required yet -- this is the heads-up that the fix is coming." \
        && alerted=1
fi

[[ "$alerted" -eq 0 ]] && log "still on $INSTALLED, no non-beta available, stubs clean"
exit 0
