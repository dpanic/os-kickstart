#!/bin/bash
set -euo pipefail

# Kernel & network optimization: sysctl, limits, scheduler, autotune
# Author: Dusan Panic <dpanic@gmail.com>
# Source: https://github.com/dpanic/patchfiles
# Safe to re-run -- idempotent
#
# Usage:
#   ./optimize.sh                           # apply all optimizations
#   ./optimize.sh sysctl limits scheduler   # apply only listed components
#
# Requires: sudo (all files are system-level)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_DIR/lib.sh"

ALL_COMPONENTS=(sysctl limits scheduler autotune)
parse_update_flag "$@"
COMPONENTS=("${_CLEAN_ARGS[@]}")
if [[ ${#COMPONENTS[@]} -eq 0 ]]; then
    COMPONENTS=("${ALL_COMPONENTS[@]}")
fi

want() {
    local c
    for c in "${COMPONENTS[@]}"; do [[ "$c" == "$1" ]] && return 0; done
    return 1
}

STEP=0
count_steps() {
    local total=0
    for c in "${ALL_COMPONENTS[@]}"; do want "$c" && total=$((total + 1)); done
    echo "$total"
}
TOTAL=$(count_steps)
next() { STEP=$((STEP + 1)); echo "[$STEP/$TOTAL] $1..."; }

backup_file() {
    local target="$1"
    if [[ -f "$target" ]]; then
        sudo cp "$target" "${target}.bak-kickstart"
        echo "  backup: ${target}.bak-kickstart"
    fi
}

append_if_missing() {
    local target="$1"
    local marker="$2"
    local content="$3"
    if grep -qF "$marker" "$target" 2>/dev/null; then
        skip "already present in $target"
    else
        backup_file "$target"
        echo "$content" | sudo tee -a "$target" >/dev/null
        echo "  appended to $target"
    fi
}

TITLE="Optimization"
[[ "$UNINSTALL" == true ]] && TITLE="Revert"
echo "=== Kernel & Network $TITLE ==="
echo "  Components: ${COMPONENTS[*]}"
echo ""

if [[ "$UNINSTALL" == true ]]; then
    if want "autotune"; then
        echo "[REVERT] autotune service..."
        sudo systemctl stop autotune.service 2>/dev/null || true
        sudo systemctl disable autotune.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/autotune.service /usr/bin/autotune.sh
        sudo systemctl daemon-reload
        remove "autotune service and script removed"
    fi

    if want "scheduler"; then
        echo "[REVERT] I/O scheduler..."
        sudo rm -f /etc/udev/rules.d/60-scheduler.rules
        sudo udevadm control --reload 2>/dev/null || true
        remove "scheduler udev rule removed"
    fi

    if want "limits"; then
        echo "[REVERT] limits..."
        if [[ -f /etc/security/limits.conf.bak-kickstart ]]; then
            sudo cp /etc/security/limits.conf.bak-kickstart /etc/security/limits.conf
            remove "limits.conf restored from backup"
        else
            skip "no limits.conf backup found"
        fi
    fi

    if want "sysctl"; then
        echo "[REVERT] sysctl..."
        if [[ -f /etc/sysctl.conf.bak-kickstart ]]; then
            sudo cp /etc/sysctl.conf.bak-kickstart /etc/sysctl.conf
            sudo sysctl -p >/dev/null 2>&1 || true
            remove "sysctl.conf restored from backup"
        else
            skip "no sysctl.conf backup found"
        fi
    fi

    echo ""
    echo "=== Kernel optimization revert complete ==="
    echo "  A reboot is recommended to fully apply reverted settings."
    exit 0
fi

# ── sysctl.conf ───────────────────────────────────────────────────────────────
if want "sysctl"; then
    next "sysctl.conf"

    backup_file /etc/sysctl.conf
    sudo cp "$SCRIPT_DIR/sysctl.conf" /etc/sysctl.conf
    sudo sysctl -p >/dev/null 2>&1 || echo "  warning: some sysctl params may require autotune/reboot"
    echo "  done: /etc/sysctl.conf (from modules/kernel/sysctl.conf)"
fi

# ── limits ────────────────────────────────────────────────────────────────────
if want "limits"; then
    next "file descriptor & process limits"

    backup_file /etc/security/limits.conf
    sudo cp "$SCRIPT_DIR/limits.conf" /etc/security/limits.conf
    echo "  done: /etc/security/limits.conf (from modules/kernel/limits.conf)"

    # PAM session modules -- append if missing
    append_if_missing /etc/pam.d/common-session \
        "pam_limits.so" \
        "# KICKSTART -- enable pam_limits for desktop sessions
session required pam_limits.so"

    append_if_missing /etc/pam.d/common-session-noninteractive \
        "pam_limits.so" \
        "# KICKSTART -- enable pam_limits for SSH sessions
session required pam_limits.so"

    # systemd DefaultLimitNOFILE -- append if missing
    append_if_missing /etc/systemd/system.conf \
        "DefaultLimitNOFILE=2097152" \
        "# KICKSTART -- increase systemd file descriptor limit
DefaultLimitNOFILE=2097152"

    append_if_missing /etc/systemd/user.conf \
        "DefaultLimitNOFILE=2097152" \
        "# KICKSTART -- increase systemd user file descriptor limit
DefaultLimitNOFILE=2097152"

    echo "  done: limits + PAM + systemd"
fi

# ── scheduler ─────────────────────────────────────────────────────────────────
if want "scheduler"; then
    next "I/O scheduler (none -- best for SSD/NVMe)"

    sudo cp "$SCRIPT_DIR/60-scheduler.rules" /etc/udev/rules.d/60-scheduler.rules
    sudo udevadm control --reload 2>/dev/null || true
    sudo udevadm trigger 2>/dev/null || true
    echo "  done: /etc/udev/rules.d/60-scheduler.rules (from modules/kernel/60-scheduler.rules)"
fi

# ── autotune ──────────────────────────────────────────────────────────────────
if want "autotune"; then
    next "RAM-based autotune (conntrack, tw_buckets, file-max)"

    sudo cp "$SCRIPT_DIR/autotune.sh" /usr/bin/autotune.sh
    sudo chmod +x /usr/bin/autotune.sh

    sudo cp "$SCRIPT_DIR/autotune.service" /etc/systemd/system/autotune.service
    sudo systemctl daemon-reload
    sudo systemctl enable autotune.service 2>/dev/null || true
    echo "  done: /usr/bin/autotune.sh + autotune.service (from modules/kernel/)"
fi

echo ""
echo "=== Kernel optimization complete ==="
echo "  Applied: ${COMPONENTS[*]}"
echo ""
echo "  A reboot is recommended to fully apply all changes."
