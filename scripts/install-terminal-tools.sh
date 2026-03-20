#!/bin/bash
set -euo pipefail

# Install terminal tools: byobu/tmux, ncdu
# Author: Dusan Panic <dpanic@gmail.com>
# Safe to re-run -- idempotent
#
# Usage:
#   ./install-terminal-tools.sh        # install everything
#   ./install-terminal-tools.sh byobu  # install only byobu+tmux

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib.sh"

ALL_COMPONENTS=(byobu ncdu)
COMPONENTS=("$@")
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

echo "=== Terminal Tools Setup ==="
echo "  Components: ${COMPONENTS[*]}"
echo ""

# ── byobu + tmux ─────────────────────────────────────────────────────────────
if want "byobu"; then
    next "byobu + tmux"

    if is_linux; then
        PKGS=()
        if command -v byobu &>/dev/null; then
            skip "byobu already installed"
        else
            PKGS+=(byobu)
        fi

        if command -v tmux &>/dev/null; then
            skip "tmux $(tmux -V) already installed"
        else
            PKGS+=(tmux)
        fi

        if [[ ${#PKGS[@]} -gt 0 ]]; then
            install "installing ${PKGS[*]}"
            pkg_install "${PKGS[@]}"
        fi

        # byobu config
        BYOBU_DIR="$HOME/.byobu"
        BYOBU_CONFIGS=(".tmux.conf" ".ctrl-a-workaround" "backend" "color.tmux" "datetime.tmux" "keybindings" "keybindings.tmux" "status")

        if [[ -d "$BYOBU_DIR" ]]; then
            local_changed=0
            for cfg in "${BYOBU_CONFIGS[@]}"; do
                src="$REPO_DIR/configs/byobu/$cfg"
                dst="$BYOBU_DIR/$cfg"
                if [[ ! -f "$src" ]]; then
                    continue
                fi
                if [[ -f "$dst" ]] && diff -q "$src" "$dst" &>/dev/null; then
                    continue
                fi
                if [[ -f "$dst" ]]; then
                    install "updating $cfg (old backed up to ${cfg}.bak)"
                    cp "$dst" "${dst}.bak"
                else
                    install "copying $cfg"
                fi
                cp "$src" "$dst"
                local_changed=$((local_changed + 1))
            done
            if [[ $local_changed -eq 0 ]]; then
                skip "byobu config already up to date"
            fi
        else
            install "creating ~/.byobu/ with configs"
            mkdir -p "$BYOBU_DIR"
            for cfg in "${BYOBU_CONFIGS[@]}"; do
                src="$REPO_DIR/configs/byobu/$cfg"
                [[ -f "$src" ]] && cp "$src" "$BYOBU_DIR/$cfg"
            done
        fi

        if [[ -f "$BYOBU_DIR/backend" ]] && grep -q "tmux" "$BYOBU_DIR/backend"; then
            skip "byobu backend already set to tmux"
        else
            install "setting byobu backend to tmux"
            echo "BYOBU_BACKEND=tmux" > "$BYOBU_DIR/backend"
        fi
    fi

    if is_macos; then
        if command -v tmux &>/dev/null; then
            skip "tmux $(tmux -V) already installed"
        else
            install "installing tmux via brew"
            pkg_install tmux
        fi
    fi
fi

# ── ncdu ──────────────────────────────────────────────────────────────────────
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
want "byobu" && echo "  byobu         -- launch terminal multiplexer"
want "ncdu"  && echo "  ncdu           -- interactive disk usage analyzer"
