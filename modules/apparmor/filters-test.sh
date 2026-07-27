#!/bin/bash
# Regression test for the DENIED noise filters in check.sh.
# Self-contained: fixtures are real kernel audit lines, no journal needed.
#
#   bash modules/apparmor/filters-test.sh
#
# Exists because a rejected regex used to be indistinguishable from "everything
# was noise": `grep -v ... || true` swallowed grep's exit 2, denied_lines went
# empty, and the monitor silently stopped alerting on anything at all. TEST 1
# pins that down -- note -P may be ugrep, which rejects `(|x)` where GNU grep
# accepts it, so a pattern that works on one host can blind another.

set -uo pipefail
SRC="$(dirname "${BASH_SOURCE[0]}")/check.sh"

# Load drop_noise straight out of check.sh -- sourcing the whole file would run
# its main body (and exit early on the unreadable root-owned webhook-url).
eval "$(awk '/^drop_noise\(\) \{/,/^\}/' "$SRC")"
[[ $(type -t drop_noise) == function ]] || { echo "cannot load drop_noise from $SRC"; exit 1; }

fail=0
check() { # check <want> <got> <label>
    if [[ "$1" == "$2" ]]; then echo "  ok   $3"; else echo "  FAIL $3 (want=$1 got=$2)"; fail=1; fi
}

# ── fixtures ────────────────────────────────────────────────────────────────
N_MQUEUE='apparmor="DENIED" operation="open" class="posix_mqueue" info="Failed name lookup - disconnected IPC path" error=-13 profile="vscode" pid=1 comm="claude" requested="read" denied="read"'
N_UNNAMED='apparmor="DENIED" operation="getattr" class="file" info="Failed name lookup - disconnected path" error=-13 profile="desktop-icons-ng" name="" pid=1 comm="bwrap" requested_mask="r" denied_mask="r"'
N_UIDMAP='apparmor="DENIED" operation="open" class="file" info="Failed name lookup - disconnected path" error=-13 profile="desktop-icons-ng" name="proc/1234/uid_map" pid=1 comm="bwrap" requested_mask="wr" denied_mask="wr"'
N_CUPSCAP='apparmor="DENIED" operation="capable" class="cap" profile="/usr/sbin/cupsd" pid=1 comm="cupsd" capability=24  capname="sys_resource"'
N_CUPSFILE='apparmor="DENIED" operation="open" class="file" profile="/usr/sbin/cupsd" name="/etc/paperspecs" pid=1 comm="cupsd" requested_mask="r" denied_mask="r"'
N_URG='apparmor="DENIED" operation="signal" profile="docker-default" pid=1 comm="go" requested_mask="receive" denied_mask="receive" signal=urg'

# must SURVIVE -- these are real breakage or real policy decisions
R_DINGLIB='apparmor="DENIED" operation="getattr" class="file" profile="desktop-icons-ng" name="/usr/lib/x86_64-linux-gnu/libselinux.so.1" pid=1 comm="ding.js" requested_mask="r" denied_mask="r"'
R_CUPSCAP='apparmor="DENIED" operation="capable" class="cap" profile="/usr/sbin/cupsd" pid=1 comm="cupsd" capability=21  capname="sys_ptrace"'
R_NAMEDDISC='apparmor="DENIED" operation="open" class="file" info="Failed name lookup - disconnected path" error=-13 profile="someapp" name="/etc/shadow" pid=1 comm="evil" requested_mask="r" denied_mask="r"'
R_MQNAMED='apparmor="DENIED" operation="open" class="posix_mqueue" profile="vscode" name="/realqueue" pid=1 comm="claude" requested="read" denied="read"'

# the filter chain exactly as check_violations applies it
chain() {
    drop_noise 'profile="[^"]*//null-' \
    | drop_noise 'operation="signal".*signal=urg' \
    | drop_noise 'class="posix_mqueue".*info="Failed name lookup - disconnected IPC path"' \
    | drop_noise -P 'class="file".*info="Failed name lookup - disconnected path".*name="(proc/[0-9]+/(uid_map|gid_map|setgroups))?"' \
    | drop_noise -P 'profile="/usr/sbin/cups(d|-browsed)".*(capname="(sys_resource|sys_admin|net_admin)"|name="(/etc/paperspecs|/usr/share/coreutils/locales/[^"]+)")'
}

echo "TEST 1 -- a rejected pattern must keep every line, never blind the monitor"
# Unmatched paren: GNU grep -P exits 2 on this. (Do NOT use `x(|y)z` here --
# GNU grep accepts empty alternation, so it would make this test vacuous.)
check 3 "$(printf 'a\nb\nc\n' | drop_noise -P 'x(y' | grep -c .)" "bad regex passes all input through"

echo "TEST 2 -- each noise fixture is dropped"
for f in N_MQUEUE N_UNNAMED N_UIDMAP N_CUPSCAP N_CUPSFILE N_URG; do
    check 0 "$(printf '%s\n' "${!f}" | chain | grep -c .)" "$f dropped"
done

echo "TEST 3 -- real denials survive the chain"
for f in R_DINGLIB R_CUPSCAP R_NAMEDDISC R_MQNAMED; do
    check 1 "$(printf '%s\n' "${!f}" | chain | grep -c .)" "$f kept"
done

echo "TEST 4 -- mixed batch keeps exactly the real ones"
all=$(printf '%s\n' "$N_MQUEUE" "$R_DINGLIB" "$N_UNNAMED" "$R_CUPSCAP" "$N_CUPSCAP" "$R_NAMEDDISC" "$N_UIDMAP" "$R_MQNAMED" "$N_CUPSFILE" "$N_URG")
check 4 "$(printf '%s\n' "$all" | chain | grep -c .)" "4 of 10 survive"

echo
[[ $fail -eq 0 ]] && echo "PASS" || echo "FAIL"
exit $fail
