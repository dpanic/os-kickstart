#!/bin/bash
# Table-driven tests for the kickstart_netdev_* functions in autotune.sh.
set -uo pipefail

SRC="$(dirname "${BASH_SOURCE[0]}")/autotune.sh"
# shellcheck source=autotune.sh
source "$SRC"
[[ $(type -t kickstart_netdev_usecs) == function ]] || {
    echo "cannot load kickstart_netdev_usecs from $SRC"
    exit 1
}

fail=0
check() {
    if [[ "$1" == "$2" ]]; then
        echo "  ok   $3"
    else
        echo "  FAIL $3 (want=$1 got=$2)"
        fail=1
    fi
}

echo "TEST 1 -- usecs is 2 jiffies: the kernel default AND its enforced minimum"
check 2000  "$(kickstart_netdev_usecs 1000)" "HZ=1000 -> 2000us"
check 8000  "$(kickstart_netdev_usecs 250)"  "HZ=250 -> 8000us (the shipped 6000 was EINVAL here)"
check 20000 "$(kickstart_netdev_usecs 100)"  "HZ=100 -> 20000us (6000 was a reduction here)"
check 6666  "$(kickstart_netdev_usecs 300)"  "HZ=300 -> same integer division as the kernel"

echo "TEST 2 -- HZ comes from the kernel config"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/boot" "$tmp/none"
printf 'CONFIG_HZ_250=y\nCONFIG_HZ=250\n' >"$tmp/boot/config-$(uname -r)"
check 250 "$(KICKSTART_BOOT=$tmp/boot KICKSTART_PROC=$tmp/none kickstart_netdev_hz)" \
    "CONFIG_HZ=250 parsed"

echo "TEST 3 -- unknown config falls back to the finest tick, never to a coarse one"
check 1000 "$(KICKSTART_BOOT=$tmp/none KICKSTART_PROC=$tmp/none kickstart_netdev_hz)" \
    "no config -> 1000"
printf 'CONFIG_HZ=garbage\n' >"$tmp/boot/config-$(uname -r)"
check 1000 "$(KICKSTART_BOOT=$tmp/boot KICKSTART_PROC=$tmp/none kickstart_netdev_hz)" \
    "non-numeric CONFIG_HZ -> 1000"

echo "TEST 4 -- the fallback is safe: it can only ever ask for the kernel's own minimum"
# 1000 is the finest tick Linux supports, so 2*1e6/1000 = 2000 is the smallest legal
# value. A wrong-high guess is refused by the kernel and leaves its default; a wrong-low
# guess would install a real multi-millisecond non-preemptible window.
check 2000 "$(kickstart_netdev_usecs "$(KICKSTART_BOOT=$tmp/none KICKSTART_PROC=$tmp/none kickstart_netdev_hz)")" \
    "fallback yields the minimum, not a longer window"

echo
[[ $fail -eq 0 ]] && echo "PASS" || echo "FAIL"
exit $fail
