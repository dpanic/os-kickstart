#!/bin/bash
set -euo pipefail

# Install PeaZip archiver (Homebrew cask on macOS, .deb on Linux)
# Author: Dusan Panic <dpanic@gmail.com>
# Handles 200+ archive formats (7z, rar, zip, tar, zstd, brotli, etc.)
# Safe to re-run -- idempotent

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib.sh"

echo "=== PeaZip Archiver ==="
echo ""

# [1/2] Install PeaZip
echo "[1/2] peazip..."
if is_macos; then
    if [[ -d /Applications/PeaZip.app ]] || command -v peazip &>/dev/null; then
        skip "PeaZip already installed"
    else
        install "installing PeaZip via Homebrew cask"
        cask_install peazip
        echo "  installed: PeaZip.app"
    fi
elif is_linux; then
    if dpkg -l peazip &>/dev/null 2>&1 && dpkg -l peazip | grep -q '^ii'; then
        PEAZIP_VER=$(dpkg -l peazip | awk '/^ii/{print $3}')
        skip "peazip ${PEAZIP_VER} already installed"
    else
        install "fetching latest PeaZip GTK2 .deb from GitHub"
        DEB_URL=$(curl -fsSL https://api.github.com/repos/peazip/PeaZip/releases/latest \
            | grep '"browser_download_url"' \
            | grep -i 'gtk2.*amd64\.deb\|amd64.*gtk2.*\.deb' \
            | head -1 \
            | cut -d'"' -f4)

        if [[ -z "$DEB_URL" ]]; then
            DEB_URL=$(curl -fsSL https://api.github.com/repos/peazip/PeaZip/releases/latest \
                | grep '"browser_download_url"' \
                | grep -i '\.deb' \
                | grep -iv 'qt' \
                | head -1 \
                | cut -d'"' -f4)
        fi

        if [[ -z "$DEB_URL" ]]; then
            echo "  ERROR: could not find PeaZip .deb in latest release"
            echo "  Check: https://github.com/peazip/PeaZip/releases"
            exit 1
        fi

        TMP_DEB=$(mktemp /tmp/peazip-XXXXXX.deb)
        echo "  downloading: $DEB_URL"
        curl -fsSL -o "$TMP_DEB" "$DEB_URL"
        sudo dpkg -i "$TMP_DEB" || sudo apt-get install -f -y
        rm -f "$TMP_DEB"

        PEAZIP_VER=$(dpkg -l peazip 2>/dev/null | awk '/^ii/{print $3}' || echo '?')
        echo "  installed: peazip ${PEAZIP_VER}"
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
