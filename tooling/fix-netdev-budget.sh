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
# Run it ON the Proxmox host of a site. Inventory, SSH identity and stale host keys are
# all worked out on their own.
#
#   ./fix-netdev-budget.sh            show what would change, touch nothing
#   ./fix-netdev-budget.sh --apply    remove the keys, restore the kernel defaults
#   ./fix-netdev-budget.sh --revert   put the previous file and values back
#
# Escape hatches, none of them needed on a normal run:
#   --hosts a,b,c / --single H   bypass the /etc/hosts inventory
#   --guest-suffix SUF           inventory marker, default "-s1"
#   --key PATH                   pin the identity instead of discovering it
#   --user USER                  force the login; default defers to ~/.ssh/config
#   --jobs N                     parallelism, default 8
#   --yes                        skip the confirmation prompt

RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; CYAN="\033[0;36m"; NC="\033[0m"

MODE="report"
GUEST_SUFFIX="-s1"
SSH_KEY=""
SSH_USER=""
JOBS=8
SINGLE=""
HOSTS_CSV=""
ASSUME_YES=false

log() { echo -e "$@"; }
die() { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)        MODE="apply" ;;
        --revert)       MODE="revert" ;;
        --single)       SINGLE="${2:?--single needs a host}"; shift ;;
        --hosts)        HOSTS_CSV="${2:?--hosts needs a list}"; shift ;;
        --guest-suffix) GUEST_SUFFIX="${2:?--guest-suffix needs a value}"; shift ;;
        --key)          SSH_KEY="${2:?--key needs a path}"; shift ;;
        --user)         SSH_USER="${2?--user needs a value}"; shift ;;
        --jobs)         JOBS="${2:?--jobs needs a number}"; shift ;;
        --yes|-y)       ASSUME_YES=true ;;
        -h|--help)      sed -n '3,35p' "$0"; exit 0 ;;
        *)              die "unknown argument: $1" ;;
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
ssh_opts() {
    printf '%s\n' -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new
    [ -n "$SSH_KEY" ] && printf '%s\n' -i "$SSH_KEY" -o IdentitiesOnly=yes
    return 0
}

# An empty SSH_USER leaves the login to ~/.ssh/config. A hand-maintained fleet does not
# use one account -- proxies log in as a service account, guests as an operator -- and
# hardcoding one silently connects as the wrong user.
ssh_target() { if [ -n "$SSH_USER" ]; then printf '%s@%s\n' "$SSH_USER" "$1"; else printf '%s\n' "$1"; fi; }

# Proxmox hosts are logged into as root and ship no sudo at all, so asking for it
# unconditionally fails on the very machine this is meant to be run from.
remote_cmd() {
    printf 'if [ "$(id -u)" -eq 0 ]; then bash -s -- %q %q; else sudo bash -s -- %q %q; fi' \
        "$MODE" "$STAMP" "$MODE" "$STAMP"
}

# Retire a host key that no longer matches. Guests do get rebuilt and their host keys
# legitimately change -- but a changed key is also exactly what a MITM looks like, so
# the old and new fingerprints are recorded and printed at the end. Automatic, but not
# silent: the evidence outlives the run.
retire_host_key() {
    local h="$1" ip old new
    old=$(ssh-keygen -F "$h" 2>/dev/null | awk '!/^#/{print $3}' | head -c 24)
    ssh-keygen -R "$h" >/dev/null 2>&1 || true
    ip=$(getent hosts "$h" 2>/dev/null | awk '{print $1; exit}')
    [ -n "$ip" ] && { ssh-keygen -R "$ip" >/dev/null 2>&1 || true; }
    new=$(ssh-keyscan -T 5 "$h" 2>/dev/null | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' | head -1)
    printf '%s%s  was=%s...  now=%s\n' \
        "$h" "${ip:+ ($ip)}" "${old:-unknown}" "${new:-unknown}" >>"$KEYLOG"
}

run_one() {
    local host="$1" out rc
    mapfile -t OPTS < <(ssh_opts)
    out=$(remote_payload | timeout 60 ssh "${OPTS[@]}" "$(ssh_target "$host")" "$(remote_cmd)" 2>&1) && rc=0 || rc=$?
    if printf '%s' "$out" | grep -q 'REMOTE HOST IDENTIFICATION HAS CHANGED'; then
        retire_host_key "$host"
        out=$(remote_payload | timeout 60 ssh "${OPTS[@]}" "$(ssh_target "$host")" "$(remote_cmd)" 2>&1) && rc=0 || rc=$?
    fi
    if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -qE '^(OK|FAIL|TODO|CLEAN|REVERTED)'; then
        printf '%s\tUNREACHABLE\t%s\n' "$host" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"
        return 0
    fi
    printf '%s\t%s\n' "$host" "$(printf '%s' "$out" | tr '\n' ' ')"
}

# Which login opens these hosts? Site keys have non-default names (…-vms) that ssh never
# offers on its own, and /root/.ssh/config is hand-written -- setup-proxmox-hosts.sh does
# not create it, so a site may have no stanza at all. The operator should not have to
# know either the key or the account, so probe for both against one live host.
#
# Each attempt is its own connection, so sshd's MaxAuthTries (6) is not a concern; the
# cost is wall clock, which is why the probe timeout is short and the loop stops at the
# first success. Order matters: whatever ssh already does is tried first so a working
# setup is never second-guessed, then the site accounts, and backup keys last -- a .bak
# key can still authenticate somewhere and would otherwise be preferred over the live one.
try_login() {
    local user="$1" key="$2" probe="$3" tgt
    if [ -n "$user" ]; then tgt="$user@$probe"; else tgt="$probe"; fi
    if [ -n "$key" ]; then
        timeout 12 ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new \
            -i "$key" -o IdentitiesOnly=yes "$tgt" true >/dev/null 2>&1
    else
        timeout 12 ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new \
            "$tgt" true >/dev/null 2>&1
    fi
}

discover_login() {
    local probe="$1" k u cands=() bak=() keys=() users=()
    if [ -n "$SSH_KEY" ]; then log "  login: ${SSH_USER:+$SSH_USER@}<host> key=$SSH_KEY (pinned)"; return; fi

    if try_login "$SSH_USER" "" "$probe"; then
        log "  login: ${SSH_USER:-<ssh_config>} via ssh-agent / ~/.ssh/config"
        return
    fi

    for k in "$HOME"/.ssh/*; do
        [ -f "$k" ] || continue
        case "$k" in *.pub|*known_hosts*|*/config*|*authorized_keys*) continue ;; esac
        grep -qs 'PRIVATE KEY' "$k" || continue
        case "$k" in *.bak*|*~) bak+=("$k") ;; *) cands+=("$k") ;; esac
    done
    keys=("" ${cands[@]+"${cands[@]}"} ${bak[@]+"${bak[@]}"})
    # "" keeps whatever ssh_config says; `user` is the cloud-init CIUSER these sites
    # deploy with; root covers a hypervisor probing itself.
    if [ -n "$SSH_USER" ]; then users=("$SSH_USER"); else users=("" user root ubuntu debian); fi

    for u in "${users[@]}"; do
        for k in "${keys[@]}"; do
            [ -z "$u" ] && [ -z "$k" ] && continue   # already tried above
            if try_login "$u" "$k" "$probe"; then
                SSH_USER="$u"; SSH_KEY="$k"
                log "  login: ${u:-<ssh_config>}@<host>${k:+ key=$k} (discovered)"
                return
            fi
        done
    done
    log "  ${YELLOW}login: nothing authenticated against $probe; falling back to ssh defaults${NC}"
}

main() {
    STAMP="$(date +%Y%m%d-%H%M%S)"
    KEYLOG="$(mktemp)"
    trap 'rm -f "$KEYLOG"' EXIT

    mapfile -t FLEET < <(resolve_inventory)
    [ "${#FLEET[@]}" -gt 0 ] || die "inventory is empty (suffix '$GUEST_SUFFIX'?)"

    log "${CYAN}=== fix-netdev-budget: mode=$MODE hosts=${#FLEET[@]} ===${NC}"
    printf '  %s\n' "${FLEET[@]}"
    log ""

    # A changed host key blocks the identity probe too, so clear the probe host first.
    # Capture, never pipe: ssh exits 255 on a rejected key and `set -o pipefail` would make
    # `ssh ... | grep -q` false in precisely the case being tested for.
    probe_host="${FLEET[0]}"
    mapfile -t OPTS < <(ssh_opts)
    probe_out=$(timeout 15 ssh "${OPTS[@]}" "$(ssh_target "$probe_host")" true 2>&1) || true
    printf '%s' "$probe_out" | grep -q 'REMOTE HOST IDENTIFICATION HAS CHANGED' && retire_host_key "$probe_host"
    discover_login "$probe_host"
    export MODE SSH_USER SSH_KEY STAMP KEYLOG
    export -f run_one remote_payload ssh_opts ssh_target remote_cmd retire_host_key
    log ""

    if [ "$MODE" != "report" ] && [ "$ASSUME_YES" != true ]; then
        log "${YELLOW}About to run '$MODE' on the ${#FLEET[@]} hosts listed above.${NC}"
        read -r -p "Type yes to continue: " ans
        [ "$ans" = "yes" ] || die "aborted"
    fi

    RESULTS=$(printf '%s\n' "${FLEET[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {})

    if [ -s "$KEYLOG" ]; then
        log "${YELLOW}=== host keys retired -- audit these ===${NC}"
        sed 's/^/  /' "$KEYLOG"
        log ""
    fi

    log "${CYAN}=== results ===${NC}"
    printf '%s\n' "$RESULTS" | sort | while IFS=$'\t' read -r host rest; do
        case "$rest" in
            OK*|CLEAN*|REVERTED*) printf "  ${GREEN}%-20s${NC} %s\n" "$host" "$rest" ;;
            TODO*)                printf "  ${YELLOW}%-20s${NC} %s\n" "$host" "$rest" ;;
            *)                    printf "  ${RED}%-20s${NC} %s\n" "$host" "$rest" ;;
        esac
    done

    fails=$(printf '%s\n' "$RESULTS" | grep -cE $'\t'"(FAIL|UNREACHABLE)" || true)
    log ""
    if [ "$fails" -gt 0 ]; then
        log "${RED}$fails host(s) failed or were unreachable.${NC}"
        exit 1
    fi
    log "${GREEN}all ${#FLEET[@]} host(s) ok${NC}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
