#!/bin/bash
set -euo pipefail

# Install terminal tools: ncdu
# Author: Dusan Panic <dpanic@gmail.com>
# Safe to re-run -- idempotent
#
# Usage:
#   ./install.sh
#   ./install.sh ncdu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_DIR/lib.sh"

ALL_COMPONENTS=(ncdu)
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

TITLE="Setup"
[[ "$UNINSTALL" == true ]] && TITLE="Uninstall"
echo "=== Terminal Tools $TITLE ==="
echo "  Components: ${COMPONENTS[*]}"
echo ""

if [[ "$UNINSTALL" == true ]]; then
    if want "ncdu"; then
        echo "[REMOVE] ncdu..."
        if command -v ncdu &>/dev/null; then
            remove "removing ncdu"
            if is_macos; then brew uninstall ncdu 2>/dev/null || true
            else sudo apt-get remove -y ncdu 2>/dev/null || true; fi
        else
            skip "ncdu not installed"
        fi
    fi

    echo ""
    echo "=== Terminal tools uninstall complete ==="
    exit 0
fi

if want "ncdu"; then
    next "ncdu"

    if command -v ncdu &>/dev/null; then
        skip "ncdu $(ncdu --version 2>/dev/null | head -1 || echo '?') already installed"
    else
        install "installing ncdu"
        pkg_install ncdu
    fi
fi

echo ""
echo "=== Terminal tools setup complete ==="
echo "  Installed: ${COMPONENTS[*]}"
echo ""
echo "Quick start:"
want "ncdu" && echo "  ncdu  -- interactive disk usage analyzer"
