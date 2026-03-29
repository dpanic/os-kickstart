#!/bin/bash
set -euo pipefail

# Install Go programming language from go.dev tarball
# Author: Dusan Panic <dpanic@gmail.com>
# Safe to re-run -- idempotent

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_DIR/lib.sh"

parse_update_flag "$@"

GO_INSTALL_DIR="/usr/local/go"

TITLE="Install"
[[ "$UNINSTALL" == true ]] && TITLE="Uninstall"
echo "=== Go Programming Language ($TITLE) ==="
echo ""

if [[ "$UNINSTALL" == true ]]; then
    if [[ -d "$GO_INSTALL_DIR" ]]; then
        remove "removing $GO_INSTALL_DIR"
        sudo rm -rf "$GO_INSTALL_DIR"
    else
        skip "Go not installed at $GO_INSTALL_DIR"
    fi
    echo "  note: remove 'export PATH=\$PATH:/usr/local/go/bin' from your shell profile"
    echo ""
    echo "=== Go uninstall complete ==="
    exit 0
fi

install_go() {
    local label="$1"
    GO_VERSION=$(curl -fsSL https://go.dev/VERSION?m=text | head -1)

    if [[ -z "$GO_VERSION" ]]; then
        echo "  ERROR: could not determine latest Go version"
        exit 1
    fi

    $label "downloading $GO_VERSION from go.dev"

    if is_linux; then
        GO_URL="https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz"
    elif is_macos; then
        local arch="amd64"
        [[ "$(uname -m)" == "arm64" ]] && arch="arm64"
        GO_URL="https://go.dev/dl/${GO_VERSION}.darwin-${arch}.tar.gz"
    fi

    TMP_DIR=$(mktemp -d /tmp/go-XXXXXX)
    echo "  downloading: $GO_URL"
    curl -fsSL -o "$TMP_DIR/go.tar.gz" "$GO_URL"
    sudo rm -rf "$GO_INSTALL_DIR"
    sudo tar -C /usr/local -xzf "$TMP_DIR/go.tar.gz"
    rm -rf "$TMP_DIR"
    echo "  installed: $("$GO_INSTALL_DIR/bin/go" version 2>/dev/null || echo "$GO_VERSION")"
}

echo "[1/2] go..."
if command -v go &>/dev/null || [[ -x "$GO_INSTALL_DIR/bin/go" ]]; then
    if [[ "$UPDATE" == true ]]; then
        install_go update
    else
        skip "go $(go version 2>/dev/null | awk '{print $3}') already installed"
    fi
else
    install_go install
fi

echo "[2/2] PATH..."
GO_PATH_LINE='export PATH=$PATH:/usr/local/go/bin'
if echo "$PATH" | grep -q "/usr/local/go/bin"; then
    skip "/usr/local/go/bin already in PATH"
else
    echo "  Add to your .zshrc or .profile:"
    echo "    $GO_PATH_LINE"
fi

echo ""
echo "=== Go installation complete ==="
echo ""
echo "Run 'go version' to verify."
