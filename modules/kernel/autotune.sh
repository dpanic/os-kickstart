#!/usr/bin/env bash

# KICKSTART -- dynamic kernel tuning based on RAM from dpanic/patchfiles
# Tunes: nf_conntrack_max, tcp_max_tw_buckets, fs.file-max, NET_RX softirq budget
#
# Sourceable: the pure kickstart_netdev_* helpers below are unit-tested against a fake
# /boot via KICKSTART_BOOT (see modules/kernel/netdev-budget-test.sh), so the imperative
# body lives in kickstart_autotune_main() behind the main guard at the bottom.

# ── NET_RX softirq budget ─────────────────────────────────────────────────────
# Restores the kernel defaults. Deleting the keys from 90-kickstart.conf does not
# reset a running host, which is the whole reason this code exists.

kickstart_netdev_boot() { printf '%s\n' "${KICKSTART_BOOT:-/boot}"; }
kickstart_netdev_proc() { printf '%s\n' "${KICKSTART_PROC:-/proc}"; }

# net_rx_action() compares against jiffies, so this knob has 1000000/HZ granularity --
# a microsecond constant does not mean the same thing on two hosts.
kickstart_netdev_hz() {
    local hz=""
    hz=$(awk -F= '/^CONFIG_HZ=[0-9]/{print $2; exit}' \
        "$(kickstart_netdev_boot)/config-$(uname -r)" 2>/dev/null) || hz=""
    if [ -z "$hz" ]; then
        hz=$(zcat "$(kickstart_netdev_proc)/config.gz" 2>/dev/null |
            awk -F= '/^CONFIG_HZ=[0-9]/{print $2; exit}') || hz=""
    fi
    # Unknown -> assume the finest tick. Guessing high can only produce a write the
    # kernel refuses, leaving its own default -- which is the target anyway. Guessing
    # low would install a real 8-20ms non-preemptible window.
    case "$hz" in ''|*[!0-9]*) hz=1000 ;; esac
    printf '%s\n' "$hz"
}

# net/core/hotdata.c: .netdev_budget_usecs = 2 * USEC_PER_SEC / HZ, and since v6.14
# sysctl_net_core.c enforces that same value as the minimum. Never exceed it.
kickstart_netdev_usecs() { echo $(( 2 * 1000000 / $1 )); }

kickstart_netdev_apply() {
    local hz usecs cur
    hz=$(kickstart_netdev_hz)
    usecs=$(kickstart_netdev_usecs "$hz")

    cur=$(sysctl -n net.core.netdev_budget 2>/dev/null || echo 0)
    if [ "$cur" -ne 300 ]; then
        echo "Setting netdev_budget=300 (kernel default, was=$cur)"
        sysctl -w net.core.netdev_budget=300 >/dev/null
    else
        echo "netdev_budget already 300, nothing to do."
    fi

    cur=$(sysctl -n net.core.netdev_budget_usecs 2>/dev/null || echo 0)
    if [ "$cur" -ne "$usecs" ]; then
        echo "Setting netdev_budget_usecs=$usecs (2 jiffies at HZ=$hz, was=$cur)"
        sysctl -w net.core.netdev_budget_usecs="$usecs" >/dev/null 2>&1 ||
            echo "Warning: kernel refused netdev_budget_usecs=$usecs; left at $cur"
    else
        echo "netdev_budget_usecs already $cur, nothing to do."
    fi
}

kickstart_autotune_main() {
    MIN_CONNTRACK=65536
    PER_GB=65536

    MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    RAM_GB=$(awk "BEGIN {ram_gb = $MEM_KB / 1024 / 1024; print (ram_gb == int(ram_gb)) ? int(ram_gb) : int(ram_gb) + 1}")
    [ "$RAM_GB" -lt 1 ] && RAM_GB=1

    TARGET_MAX=$((RAM_GB * PER_GB))
    [ "$TARGET_MAX" -lt "$MIN_CONNTRACK" ] && TARGET_MAX=$MIN_CONNTRACK

    # conntrack_max
    if ! lsmod | grep -q "^nf_conntrack "; then
        modprobe nf_conntrack 2>/dev/null && sleep 1 || true
    fi
    if [ -f "/proc/sys/net/netfilter/nf_conntrack_max" ]; then
        CURRENT=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 0)
        if [ "$CURRENT" -ne "$TARGET_MAX" ]; then
            echo "Setting nf_conntrack_max=$TARGET_MAX (RAM=${RAM_GB}G, was=$CURRENT)"
            sysctl -w net.netfilter.nf_conntrack_max="$TARGET_MAX" >/dev/null
        fi
    fi

    # tcp_max_tw_buckets
    TW_CURRENT=$(sysctl -n net.ipv4.tcp_max_tw_buckets 2>/dev/null || echo 0)
    if [ "$TW_CURRENT" -ne "$TARGET_MAX" ]; then
        echo "Setting tcp_max_tw_buckets=$TARGET_MAX (RAM=${RAM_GB}G, was=$TW_CURRENT)"
        sysctl -w net.ipv4.tcp_max_tw_buckets="$TARGET_MAX" >/dev/null
    fi

    # fs.file-max
    FILE_MAX_PER_GB=262144
    FILE_MAX_TARGET=$((RAM_GB * FILE_MAX_PER_GB))
    [ "$FILE_MAX_TARGET" -lt 1048576 ] && FILE_MAX_TARGET=1048576

    FM_CURRENT=$(sysctl -n fs.file-max 2>/dev/null || echo 0)
    if [ "$FM_CURRENT" -ne "$FILE_MAX_TARGET" ]; then
        echo "Setting fs.file-max=$FILE_MAX_TARGET (RAM=${RAM_GB}G, was=$FM_CURRENT)"
        sysctl -w fs.file-max="$FILE_MAX_TARGET" >/dev/null
    fi

    # NET_RX softirq budget - restore the kernel defaults
    kickstart_netdev_apply

    # NIC ring buffers - set to hardware max for each active interface
    for IFACE in $(ip -o link show up | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|tap|virbr)'); do
        RX_MAX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/Pre-set/,/Current/' | awk '/^RX:/{print $2}' | head -1)
        RX_CUR=$(ethtool -g "$IFACE" 2>/dev/null | awk '/Current/,0' | awk '/^RX:/{print $2}' | head -1)
        TX_MAX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/Pre-set/,/Current/' | awk '/^TX:/{print $2}' | head -1)

        if [ -n "$RX_MAX" ] && [ -n "$RX_CUR" ] && [ "$RX_CUR" -lt "$RX_MAX" ] 2>/dev/null; then
            echo "Setting $IFACE ring buffer RX=$RX_MAX TX=$TX_MAX (was RX=$RX_CUR)"
            ethtool -G "$IFACE" rx "$RX_MAX" tx "${TX_MAX:-$RX_MAX}" 2>/dev/null || true
        else
            echo "$IFACE ring buffer already at max ($RX_CUR), nothing to do."
        fi
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    if [ "$EUID" -ne 0 ]; then
        echo "Error: must be run as root" >&2
        exit 1
    fi
    kickstart_autotune_main "$@"
fi
