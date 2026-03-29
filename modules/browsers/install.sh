#!/bin/bash
set -euo pipefail

# Install desktop apps: Chrome, Brave, Signal
# Author: Dusan Panic <dpanic@gmail.com>
# Safe to re-run -- idempotent
#
# Usage:
#   ./install-browsers.sh                # install all
#   ./install-browsers.sh chrome signal  # install only chrome and signal

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_DIR/lib.sh"

ALL_COMPONENTS=(chrome brave signal)
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
echo "=== Desktop Apps $TITLE ==="
echo "  Components: ${COMPONENTS[*]}"
echo ""

if [[ "$UNINSTALL" == true ]]; then
    if want "chrome"; then
        echo "[REMOVE] Chrome..."
        if command -v google-chrome &>/dev/null || command -v google-chrome-stable &>/dev/null; then
            remove "removing Google Chrome"
            if is_macos; then brew uninstall --cask google-chrome 2>/dev/null || true
            elif is_linux; then sudo apt-get remove -y google-chrome-stable 2>/dev/null || true; fi
        else
            skip "Chrome not installed"
        fi
    fi

    if want "brave"; then
        echo "[REMOVE] Brave..."
        if command -v brave-browser &>/dev/null; then
            remove "removing Brave"
            if is_macos; then brew uninstall --cask brave-browser 2>/dev/null || true
            elif is_linux; then sudo apt-get remove -y brave-browser 2>/dev/null || true; fi
        else
            skip "Brave not installed"
        fi
    fi

    if want "signal"; then
        echo "[REMOVE] Signal..."
        if command -v signal-desktop &>/dev/null; then
            remove "removing Signal Desktop"
            if is_macos; then brew uninstall --cask signal 2>/dev/null || true
            elif is_linux; then sudo apt-get remove -y signal-desktop 2>/dev/null || true; fi
        else
            skip "Signal not installed"
        fi
    fi

    echo ""
    echo "=== Desktop apps uninstall complete ==="
    exit 0
fi

# ── Google Chrome ─────────────────────────────────────────────────────────────
if want "chrome"; then
    next "Google Chrome"

    if command -v google-chrome &>/dev/null || command -v google-chrome-stable &>/dev/null; then
        if [[ "$UPDATE" == true ]]; then
            if is_macos; then
                update "updating Chrome via brew"
                brew upgrade --cask google-chrome 2>/dev/null || skip "Chrome already at latest"
            elif is_linux; then
                update "updating Chrome via apt"
                sudo apt-get update -qq
                sudo apt-get install --only-upgrade -y google-chrome-stable 2>/dev/null || skip "Chrome already at latest"
            fi
        else
            skip "Google Chrome already installed"
        fi
    else
        if is_macos; then
            install "installing Chrome via Homebrew cask"
            cask_install google-chrome
        elif is_linux; then
            install "downloading Chrome .deb from Google"
            TMP_DEB=$(mktemp /tmp/chrome-XXXXXX.deb)
            curl -fsSL -o "$TMP_DEB" "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
            sudo dpkg -i "$TMP_DEB" || sudo apt-get install -f -y
            rm -f "$TMP_DEB"
            echo "  installed: $(google-chrome --version 2>/dev/null || echo 'Google Chrome')"
        fi
    fi
fi

# ── Brave ─────────────────────────────────────────────────────────────────────
if want "brave"; then
    next "Brave"

    if command -v brave-browser &>/dev/null; then
        if [[ "$UPDATE" == true ]]; then
            if is_macos; then
                update "updating Brave via brew"
                brew upgrade --cask brave-browser 2>/dev/null || skip "Brave already at latest"
            elif is_linux; then
                update "updating Brave via apt"
                sudo apt-get update -qq
                sudo apt-get install --only-upgrade -y brave-browser 2>/dev/null || skip "Brave already at latest"
            fi
        else
            skip "Brave already installed"
        fi
    else
        if is_macos; then
            install "installing Brave via Homebrew cask"
            cask_install brave-browser
        elif is_linux; then
            install "adding Brave apt repository"
            sudo curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
                https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
            sudo curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources \
                https://brave-browser-apt-release.s3.brave.com/brave-browser.sources
            install "installing Brave"
            sudo apt-get update -qq
            sudo apt-get install -y brave-browser
            echo "  installed: $(brave-browser --version 2>/dev/null || echo 'Brave')"
        fi
    fi
fi

# ── Signal ────────────────────────────────────────────────────────────────────
if want "signal"; then
    next "Signal Desktop"

    if command -v signal-desktop &>/dev/null; then
        if [[ "$UPDATE" == true ]]; then
            if is_macos; then
                update "updating Signal via brew"
                brew upgrade --cask signal 2>/dev/null || skip "Signal already at latest"
            elif is_linux; then
                update "updating Signal via apt"
                sudo apt-get update -qq
                sudo apt-get install --only-upgrade -y signal-desktop 2>/dev/null || skip "Signal already at latest"
            fi
        else
            skip "Signal Desktop already installed"
        fi
    else
        if is_macos; then
            install "installing Signal via Homebrew cask"
            cask_install signal
        elif is_linux; then
            install "adding Signal apt repository"
            curl -fsSL https://updates.signal.org/desktop/apt/keys.asc \
                | gpg --dearmor \
                | sudo tee /usr/share/keyrings/signal-desktop-keyring.gpg >/dev/null
            sudo curl -fsSLo /etc/apt/sources.list.d/signal-desktop.sources \
                https://updates.signal.org/static/desktop/apt/signal-desktop.sources
            install "installing Signal Desktop"
            sudo apt-get update -qq
            sudo apt-get install -y signal-desktop
            echo "  installed: Signal Desktop"
        fi
    fi
fi

echo ""
echo "=== Desktop apps setup complete ==="
echo "  Installed: ${COMPONENTS[*]}"
