#!/usr/bin/env bash
set -euo pipefail

# Remove net.core.netdev_budget / netdev_budget_usecs from a fleet and restore the
# kernel defaults.
#
# Both keys shipped for years via patchfiles/os-kickstart and neither is defensible:
#
#   netdev_budget = 30000   net_rx_action() processes at most (NAPI instances on that
#                           CPU) * NAPI_POLL_WEIGHT(64) packets per round. A typical host
#                           has one device NAPI plus the backlog = 128 packets. 30000
#                           would need 469 NAPI instances on one core to ever bind; even
#                           the kernel default of 300 needs 5. It is inert.
#   netdev_budget_usecs     Kernel default is 2 * USEC_PER_SEC / HZ. Every host measured
#                     = 6000 is CONFIG_HZ=1000, so this is a 3x longer non-preemptible
#                           NET_RX window with no measured benefit -- packet loss across
#                           the fleet is zero. Since v6.14 the kernel also refuses
#                           anything below its own default, so no static value ports.
#
# Deleting the line does NOT reset a running host, so this restores the runtime value too.
#
# Run it ON the Proxmox host of a site (inventory comes from the managed block of
# /etc/hosts), or anywhere with --hosts.
#
# Usage:
#   ./fix-netdev-budget.sh                          # dry-run over the resolved inventory
#   ./fix-netdev-budget.sh --apply
#   ./fix-netdev-budget.sh --revert                 # restore the newest backup + 30000/6000
#   ./fix-netdev-budget.sh --single storm-s1.lan
#   ./fix-netdev-budget.sh --hosts box1,box2,storage
#   ./fix-netdev-budget.sh --refresh-host-keys      # ssh-keygen -R for changed keys only
#
# Options:
#   --guest-suffix SUF   inventory marker, default "-s1" (sites differ)
#   --key PATH           ssh identity; default: the site key next to /root/.ssh
#   --user USER          ssh user on the guests, default "user"
#   --jobs N             parallelism, default 8
#   --yes                skip the confirmation prompt before --apply/--revert

RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; CYAN="\033[0;36m"; NC="\033[0m"

MODE="report"
GUEST_SUFFIX="-s1"
SSH_KEY=""
SSH_USER="user"
JOBS=8
SINGLE=""
HOSTS_CSV=""
ASSUME_YES=false
REFRESH_KEYS=false

log() { echo -e "$@"; }
die() { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)             MODE="apply" ;;
        --revert)            MODE="revert" ;;
        --refresh-host-keys) REFRESH_KEYS=true ;;
        --single)            SINGLE="${2:?--single needs a host}"; shift ;;
        --hosts)             HOSTS_CSV="${2:?--hosts needs a list}"; shift ;;
        --guest-suffix)      GUEST_SUFFIX="${2:?--guest-suffix needs a value}"; shift ;;
        --key)               SSH_KEY="${2:?--key needs a path}"; shift ;;
        --user)              SSH_USER="${2:?--user needs a name}"; shift ;;
        --jobs)              JOBS="${2:?--jobs needs a number}"; shift ;;
        --yes|-y)            ASSUME_YES=true ;;
        -h|--help)           sed -n '3,40p' "$0"; exit 0 ;;
        *)                   die "unknown argument: $1" ;;
    esac
    shift
done

# ── inventory ─────────────────────────────────────────────────────────────────
# Only guests. The managed block of /etc/hosts also carries hypervisors, keepalived
# VIPs and certificate names, and the file carries customer hardware outside it --
# none of which we may touch. The guest suffix is the only reliable marker, so
# select on it and dedupe by IP (each guest has several aliases on one line).
resolve_inventory() {
    if [ -n "$SINGLE" ]; then printf '%s\n' "$SINGLE"; return; fi
    if [ -n "$HOSTS_CSV" ]; then printf '%s\n' "${HOSTS_CSV//,/$'\n'}" | sed '/^$/d'; return; fi
    [ -r /etc/hosts ] || die "/etc/hosts not readable and neither --single nor --hosts given"
    awk -v suf="$GUEST_SUFFIX" '
        /^# === BEGIN /{inblk=1; next}
        /^# === END /  {inblk=0}
        inblk && /^[0-9]/ {
            for (i = 2; i <= NF; i++)
                if ($i ~ suf "\\.lan$") { print $1, $i; break }
        }' /etc/hosts | sort -u -k1,1 | awk '{print $2}' | sort
}

# ── the payload that runs on each host, as root ───────────────────────────────
# Kept dependency-free: bash + coreutils + sysctl only. No gawk strtonum -- Ubuntu
# ships mawk, which does not have it.
remote_payload() {
cat <<'PAYLOAD'
set -uo pipefail
MODE="$1"; TS="$2"
KEYRE='^[[:space:]]*net\.core\.netdev_budget(_usecs)?[[:space:]]*='

# /etc/sysctl.d/99-sysctl.conf is a symlink to /etc/sysctl.conf on Ubuntu. Editing
# both would back the same file up twice and the second sed would find nothing.
list_files() {
    { echo /etc/sysctl.conf; ls /etc/sysctl.d/*.conf 2>/dev/null; } |
    while read -r f; do [ -f "$f" ] && readlink -f "$f"; done | sort -u
}

hz() {
    local h=""
    h=$(awk -F= '/^CONFIG_HZ=[0-9]/{print $2; exit}' "/boot/config-$(uname -r)" 2>/dev/null)
    [ -z "$h" ] && h=$(zcat /proc/config.gz 2>/dev/null | awk -F= '/^CONFIG_HZ=[0-9]/{print $2; exit}')
    case "$h" in ''|*[!0-9]*) h=1000 ;; esac
    echo "$h"
}

HZ=$(hz)
WANT_BUDGET=300                       # net/core/hotdata.c
WANT_USECS=$(( 2 * 1000000 / HZ ))    # 2 * USEC_PER_SEC / HZ
B0=$(sysctl -n net.core.netdev_budget 2>/dev/null || echo "?")
U0=$(sysctl -n net.core.netdev_budget_usecs 2>/dev/null || echo "?")

HITS=""
for f in $(list_files); do
    grep -qE "$KEYRE" "$f" 2>/dev/null && HITS="$HITS $f"
done
HITS="${HITS# }"

case "$MODE" in
report)
    if [ -z "$HITS" ] && [ "$B0" = "$WANT_BUDGET" ] && [ "$U0" = "$WANT_USECS" ]; then
        echo "CLEAN    HZ=$HZ runtime=$B0/$U0 files=none"
    else
        echo "TODO     HZ=$HZ runtime=$B0/$U0 want=$WANT_BUDGET/$WANT_USECS files=${HITS:-none}"
    fi
    ;;
apply)
    for f in $HITS; do
        cp -a "$f" "$f.bak-netdev-$TS" || { echo "FAIL     backup of $f"; exit 1; }
        sed -i -E "/$KEYRE/d" "$f"
    done
    sysctl -w net.core.netdev_budget="$WANT_BUDGET" >/dev/null 2>&1 ||
        echo "WARN     kernel refused netdev_budget=$WANT_BUDGET"
    sysctl -w net.core.netdev_budget_usecs="$WANT_USECS" >/dev/null 2>&1 ||
        echo "WARN     kernel refused netdev_budget_usecs=$WANT_USECS (below 2*USEC_PER_SEC/HZ)"
    B1=$(sysctl -n net.core.netdev_budget 2>/dev/null || echo "?")
    U1=$(sysctl -n net.core.netdev_budget_usecs 2>/dev/null || echo "?")
    LEFT=""
    for f in $(list_files); do grep -qE "$KEYRE" "$f" 2>/dev/null && LEFT="$LEFT $f"; done
    if [ "$B1" = "$WANT_BUDGET" ] && [ "$U1" = "$WANT_USECS" ] && [ -z "$LEFT" ]; then
        echo "OK       HZ=$HZ $B0/$U0 -> $B1/$U1 edited=${HITS:-none}"
    else
        echo "FAIL     HZ=$HZ $B0/$U0 -> $B1/$U1 want=$WANT_BUDGET/$WANT_USECS leftover=${LEFT:-none}"
        exit 1
    fi
    ;;
revert)
    RESTORED=""
    for f in $(list_files); do
        b=$(ls -1t "$f".bak-netdev-* 2>/dev/null | head -1) || true
        [ -n "$b" ] && { cp -a "$b" "$f"; RESTORED="$RESTORED $f"; }
    done
    sysctl -w net.core.netdev_budget=30000 >/dev/null 2>&1 || true
    sysctl -w net.core.netdev_budget_usecs=6000 >/dev/null 2>&1 || true
    B1=$(sysctl -n net.core.netdev_budget 2>/dev/null || echo "?")
    U1=$(sysctl -n net.core.netdev_budget_usecs 2>/dev/null || echo "?")
    echo "REVERTED HZ=$HZ $B0/$U0 -> $B1/$U1 restored=${RESTORED:-none}"
    ;;
esac
PAYLOAD
}

# ── ssh ───────────────────────────────────────────────────────────────────────
# accept-new adds a host we have never seen, but still REFUSES a key that changed.
# That refusal is the point: guests get rebuilt and their host keys legitimately
# change, and silently trusting the new one would defeat the check. --refresh-host-keys
# is the deliberate, logged way to accept it.
ssh_opts() {
    printf '%s\n' -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new
    [ -n "$SSH_KEY" ] && printf '%s\n' -i "$SSH_KEY" -o IdentitiesOnly=yes
    return 0
}

run_one() {
    local host="$1" out rc
    mapfile -t OPTS < <(ssh_opts)
    out=$(remote_payload | timeout 60 ssh "${OPTS[@]}" "$SSH_USER@$host" \
        "sudo bash -s -- '$MODE' '$STAMP'" 2>&1) && rc=0 || rc=$?
    if printf '%s' "$out" | grep -q 'REMOTE HOST IDENTIFICATION HAS CHANGED'; then
        printf '%s\tKEYCHANGED\t%s\n' "$host" "host key changed; not touched"
        return 0
    fi
    if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -qE '^(OK|FAIL|TODO|CLEAN|REVERTED)'; then
        printf '%s\tUNREACHABLE\t%s\n' "$host" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"
        return 0
    fi
    printf '%s\t%s\n' "$host" "$(printf '%s' "$out" | tr '\n' ' ')"
}
export -f run_one remote_payload ssh_opts
export MODE SSH_USER SSH_KEY

STAMP="$(date +%Y%m%d-%H%M%S)"
export STAMP

mapfile -t FLEET < <(resolve_inventory)
[ "${#FLEET[@]}" -gt 0 ] || die "inventory is empty (suffix '$GUEST_SUFFIX'?)"

log "${CYAN}=== fix-netdev-budget: mode=$MODE hosts=${#FLEET[@]} user=$SSH_USER ===${NC}"
printf '  %s\n' "${FLEET[@]}"
log ""

if [ "$REFRESH_KEYS" = true ]; then
    log "${YELLOW}--refresh-host-keys: removing changed host keys${NC}"
    for h in "${FLEET[@]}"; do
        mapfile -t OPTS < <(ssh_opts)
        if timeout 20 ssh "${OPTS[@]}" "$SSH_USER@$h" true 2>&1 |
           grep -q 'REMOTE HOST IDENTIFICATION HAS CHANGED'; then
            ssh-keygen -R "$h" >/dev/null 2>&1 && log "  ${YELLOW}removed${NC} $h"
        fi
    done
    log ""
fi

if [ "$MODE" != "report" ] && [ "$ASSUME_YES" != true ]; then
    log "${YELLOW}About to run '$MODE' on the ${#FLEET[@]} hosts listed above.${NC}"
    read -r -p "Type yes to continue: " ans
    [ "$ans" = "yes" ] || die "aborted"
fi

RESULTS=$(printf '%s\n' "${FLEET[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {})

log "${CYAN}=== results ===${NC}"
printf '%s\n' "$RESULTS" | sort | while IFS=$'\t' read -r host rest; do
    case "$rest" in
        OK*|CLEAN*|REVERTED*) printf "  ${GREEN}%-20s${NC} %s\n" "$host" "$rest" ;;
        TODO*)                printf "  ${YELLOW}%-20s${NC} %s\n" "$host" "$rest" ;;
        *)                    printf "  ${RED}%-20s${NC} %s\n" "$host" "$rest" ;;
    esac
done

fails=$(printf '%s\n' "$RESULTS" | grep -cE $'\t'"(FAIL|UNREACHABLE|KEYCHANGED)" || true)
log ""
if [ "$fails" -gt 0 ]; then
    log "${RED}$fails host(s) failed, unreachable, or have a changed host key.${NC}"
    [ "$MODE" = "report" ] && log "Changed keys: re-run with --refresh-host-keys after confirming the rebuild was expected."
    exit 1
fi
log "${GREEN}all ${#FLEET[@]} host(s) ok${NC}"
