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
        if systemctl is-enabled ssh.socket &>/dev/null; then
            sudo systemctl restart ssh.socket 2>/dev/null || true
        else
            sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null || true
        fi
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

# Newer OpenSSH (Ubuntu 26.04 ships 10.x) rejects removed key types/algorithms,
# so validate the bundled config BEFORE touching the live one -- a bad config
# plus PasswordAuthentication no would otherwise lock us out.
echo "[1/2] Validating bundled sshd_config (sshd -t)..."
if ! sudo sshd -t -f "$SCRIPT_DIR/sshd_config"; then
    echo "  ERROR: bundled sshd_config fails validation -- aborting, no changes made." >&2
    exit 1
fi
echo "  ok."

echo "[2/2] Applying hardened sshd_config..."
backup_file /etc/ssh/sshd_config
sudo cp "$SCRIPT_DIR/sshd_config" /etc/ssh/sshd_config

# Re-validate the installed config; roll back immediately if it is somehow invalid.
if ! sudo sshd -t; then
    echo "  ERROR: installed sshd_config failed validation -- restoring backup." >&2
    [[ -f /etc/ssh/sshd_config.bak-kickstart ]] && sudo cp /etc/ssh/sshd_config.bak-kickstart /etc/ssh/sshd_config
    exit 1
fi

# Ubuntu 22.10+ socket-activates sshd via ssh.socket; restarting ssh.service while
# the socket owns the port conflicts, so restart the unit that is actually in use.
if systemctl is-enabled ssh.socket &>/dev/null; then
    sudo systemctl restart ssh.socket 2>/dev/null || true
else
    sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null || true
fi
echo "  done: /etc/ssh/sshd_config (password auth DISABLED)"

echo ""
echo "=== SSH hardening complete ==="
