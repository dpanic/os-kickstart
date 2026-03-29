#!/bin/bash
set -euo pipefail

# Install Yazi terminal file manager (brew on macOS, GitHub binary on Linux)
# Author: Dusan Panic <dpanic@gmail.com>
# Safe to re-run -- idempotent

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_DIR/lib.sh"

parse_update_flag "$@"

TITLE="Install"
[[ "$UNINSTALL" == true ]] && TITLE="Uninstall"
echo "=== Yazi Terminal File Manager ($TITLE) ==="
echo ""

if [[ "$UNINSTALL" == true ]]; then
    if command -v yazi &>/dev/null; then
        remove "removing yazi binary"
        sudo rm -f /usr/local/bin/yazi /usr/local/bin/ya
        if is_macos; then brew uninstall yazi 2>/dev/null || true; fi
    else
        skip "yazi not installed"
    fi
    if [[ -d "$HOME/.config/yazi" ]]; then
        remove "removing ~/.config/yazi"
        rm -rf "$HOME/.config/yazi"
    fi
    echo ""
    echo "=== Yazi uninstall complete ==="
    exit 0
fi

install_yazi_from_zip() {
    local label="$1"
    $label "downloading latest yazi binary from GitHub"
    local ZIP_URL="https://github.com/sxyazi/yazi/releases/latest/download/yazi-x86_64-unknown-linux-gnu.zip"

    TMP_DIR=$(mktemp -d /tmp/yazi-XXXXXX)
    echo "  downloading: $ZIP_URL"
    curl -fsSL -o "$TMP_DIR/yazi.zip" "$ZIP_URL"
    unzip -q "$TMP_DIR/yazi.zip" -d "$TMP_DIR"

    sudo install -m 755 "$TMP_DIR"/yazi-*/yazi /usr/local/bin/yazi
    sudo install -m 755 "$TMP_DIR"/yazi-*/ya   /usr/local/bin/ya

    rm -rf "$TMP_DIR"
    echo "  installed: $(yazi --version 2>/dev/null || echo 'yazi')"
}

# [1/3] Install yazi
echo "[1/3] yazi..."
if command -v yazi &>/dev/null; then
    if [[ "$UPDATE" == true ]]; then
        if is_macos; then
            update "updating yazi via brew"
            brew upgrade yazi 2>/dev/null || skip "yazi already at latest"
        elif is_linux; then
            install_yazi_from_zip update
        fi
    else
        skip "yazi $(yazi --version 2>/dev/null || echo '?') already installed"
    fi
else
    if is_macos; then
        pkg_install yazi
    elif is_linux; then
        install_yazi_from_zip install
    fi
fi

# [2/3] Yazi config directory
echo "[2/3] yazi config..."
YAZI_CONFIG="$HOME/.config/yazi"
if [[ -d "$YAZI_CONFIG" ]]; then
    skip "~/.config/yazi/ already exists"
else
    install "creating ~/.config/yazi/"
    mkdir -p "$YAZI_CONFIG"
fi

# [3/3] Shell wrapper for cd-on-exit behavior
echo "[3/3] yazi shell wrapper..."
WRAPPER_FILE="$YAZI_CONFIG/ya.sh"
if [[ -f "$WRAPPER_FILE" ]]; then
    skip "ya.sh wrapper already exists"
else
    install "creating ya.sh cd-on-exit wrapper"
    cat > "$WRAPPER_FILE" << 'WRAPPER'
#!/bin/bash
# Yazi wrapper: cd into the directory yazi was in when it exited
# Usage: source this file, then use `ya` instead of `yazi`
# Or add to .zshrc/.bashrc:  function ya() { ... }

function ya() {
    local tmp
    tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
    yazi "$@" --cwd-file="$tmp"
    if cwd="$(cat -- "$tmp")" && [[ -n "$cwd" ]] && [[ "$cwd" != "$PWD" ]]; then
        builtin cd -- "$cwd"
    fi
    rm -f -- "$tmp"
}
WRAPPER
    echo ""
    echo "  Add to your .zshrc to enable cd-on-exit:"
    echo "    source ~/.config/yazi/ya.sh"
fi

echo ""
echo "=== Yazi installation complete ==="
echo ""
echo "Run 'yazi' to launch, or 'ya' (after sourcing wrapper) for cd-on-exit."
