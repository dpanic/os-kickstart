#!/bin/bash
set -euo pipefail

# OpenSSH server hardening (kickstart-managed sshd_config)
# Safe to re-run -- idempotent
# Requires: sudo
#
# Usage:
#   sudo ./setup.sh
#   sudo ./setup.sh --uninstall

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_DIR/lib.sh"
parse_update_flag "$@"

backup_file() {
    local target="$1"
    if [[ -f "$target" ]]; then
        sudo cp "$target" "${target}.bak-kickstart"
        echo "  backup: ${target}.bak-kickstart"
    fi
}

if [[ "$UNINSTALL" == true ]]; then
    echo "=== SSH server -- Revert ==="
    echo ""
    if [[ -f /etc/ssh/sshd_config.bak-kickstart ]]; then
        sudo cp /etc/ssh/sshd_config.bak-kickstart /etc/ssh/sshd_config
        sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null || true
        remove "sshd_config restored from backup"
    else
        skip "no sshd backup found -- cannot revert"
    fi
    echo ""
    echo "=== SSH revert complete ==="
    exit 0
fi

echo "=== SSH server hardening ==="
echo ""

if [[ ! -f /etc/ssh/sshd_config ]]; then
    skip "openssh-server not installed (/etc/ssh/sshd_config missing)"
    exit 0
fi

echo "[1/1] Applying hardened sshd_config..."
backup_file /etc/ssh/sshd_config
sudo cp "$SCRIPT_DIR/sshd_config" /etc/ssh/sshd_config
sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null || true
echo "  done: /etc/ssh/sshd_config (password auth DISABLED)"

echo ""
echo "=== SSH hardening complete ==="
