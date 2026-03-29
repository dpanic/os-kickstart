#!/bin/bash
set -euo pipefail

# Install PeaZip archiver (Homebrew cask on macOS, .deb on Linux)
# Author: Dusan Panic <dpanic@gmail.com>
# Handles 200+ archive formats (7z, rar, zip, tar, zstd, brotli, etc.)
# Safe to re-run -- idempotent

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_DIR/lib.sh"

parse_update_flag "$@"

TITLE="Install"
[[ "$UNINSTALL" == true ]] && TITLE="Uninstall"
echo "=== PeaZip Archiver ($TITLE) ==="
echo ""

if [[ "$UNINSTALL" == true ]]; then
    if is_macos; then
        if [[ -d /Applications/PeaZip.app ]] || command -v peazip &>/dev/null; then
            remove "removing PeaZip"
            brew uninstall --cask peazip 2>/dev/null || true
        else
            skip "PeaZip not installed"
        fi
    elif is_linux; then
        if dpkg -l peazip 2>/dev/null | grep -q '^ii'; then
            remove "removing PeaZip"
            sudo apt-get remove -y peazip 2>/dev/null || true
        else
            skip "PeaZip not installed"
        fi
    fi
    echo ""
    echo "=== PeaZip uninstall complete ==="
    exit 0
fi

install_peazip_deb() {
    local label="$1"
    $label "fetching latest PeaZip GTK2 .deb from GitHub"

    local PEAZIP_VER
    PEAZIP_VER=$(curl -fsSI https://github.com/peazip/PeaZip/releases/latest 2>/dev/null \
        | grep -i '^location:' | sed 's|.*/||' | tr -d '\r\n')

    if [[ -z "$PEAZIP_VER" ]]; then
        echo "  ERROR: could not determine latest PeaZip version"
        echo "  Check: https://github.com/peazip/PeaZip/releases"
        exit 1
    fi

    local DEB_URL="https://github.com/peazip/PeaZip/releases/download/${PEAZIP_VER}/peazip_${PEAZIP_VER}.LINUX.GTK2-1_amd64.deb"

    TMP_DEB=$(mktemp /tmp/peazip-XXXXXX.deb)
    echo "  downloading: $DEB_URL"
    curl -fsSL -o "$TMP_DEB" "$DEB_URL"
    sudo dpkg -i "$TMP_DEB" || sudo apt-get install -f -y
    rm -f "$TMP_DEB"

    PEAZIP_VER=$(dpkg -l peazip 2>/dev/null | awk '/^ii/{print $3}' || echo '?')
    echo "  installed: peazip ${PEAZIP_VER}"
}

# [1/2] Install PeaZip
echo "[1/2] peazip..."
if is_macos; then
    if [[ -d /Applications/PeaZip.app ]] || command -v peazip &>/dev/null; then
        if [[ "$UPDATE" == true ]]; then
            update "updating PeaZip via Homebrew cask"
            brew upgrade --cask peazip 2>/dev/null || skip "PeaZip already at latest"
        else
            skip "PeaZip already installed"
        fi
    else
        install "installing PeaZip via Homebrew cask"
        cask_install peazip
        echo "  installed: PeaZip.app"
    fi
elif is_linux; then
    if dpkg -l peazip &>/dev/null 2>&1 && dpkg -l peazip | grep -q '^ii'; then
        if [[ "$UPDATE" == true ]]; then
            install_peazip_deb update
        else
            PEAZIP_VER=$(dpkg -l peazip | awk '/^ii/{print $3}')
            skip "peazip ${PEAZIP_VER} already installed"
        fi
    else
        install_peazip_deb install
    fi
else
    echo "  ERROR: PeaZip installer supports Linux (apt) and macOS (Homebrew) only."
    exit 1
fi

# [2/2] Verify
echo "[2/2] verification..."
if is_macos; then
    if [[ -d /Applications/PeaZip.app ]] || command -v peazip &>/dev/null; then
        skip "PeaZip found ($(command -v peazip 2>/dev/null || echo /Applications/PeaZip.app))"
    else
        echo "  PeaZip cask installed but app not found under /Applications and no peazip in PATH"
    fi
else
    if command -v peazip &>/dev/null; then
        skip "peazip binary found at $(command -v peazip)"
    else
        echo "  peazip installed via dpkg but not in PATH"
        echo "  try: /usr/bin/peazip or check the .desktop entry"
    fi
fi

echo ""
echo "=== PeaZip installation complete ==="
echo ""
if is_macos; then
    echo "PeaZip is a standalone app in Applications (open from Finder or Spotlight)."
else
    echo "PeaZip integrates with the Nautilus context menu automatically."
fi
echo "Supported formats: 7z, rar, zip, tar.gz, zstd, brotli, and 200+ more."
