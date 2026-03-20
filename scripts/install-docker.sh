#!/bin/bash
set -euo pipefail

# Install Docker: Linux (Engine + Compose from official repo) or macOS (Docker Desktop via Homebrew)
# Author: Dusan Panic <dpanic@gmail.com>
# Linux: daemon.json (logging, concurrency), docker group
# Safe to re-run -- idempotent

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib.sh"

echo "=== Docker Setup ==="
echo ""

if is_macos; then
    echo "[1/2] Docker Desktop..."
    if command -v docker &>/dev/null; then
        skip "docker already installed ($(docker --version))"
    elif [[ -d /Applications/Docker.app ]]; then
        skip "Docker Desktop already present at /Applications/Docker.app"
    else
        install "installing Docker Desktop (Homebrew cask)"
        cask_install docker
    fi

    echo "[2/2] verify docker..."
    docker --version

elif is_linux; then
    # [1/4] Docker Engine
    echo "[1/4] docker engine..."
    if command -v docker &>/dev/null; then
        skip "docker $(docker --version | head -1) already installed"
    else
        install "installing Docker from official repo"

        pkg_install ca-certificates curl

        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

        pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        echo "  installed: $(docker --version)"
    fi

    # [2/4] Docker Compose (plugin)
    echo "[2/4] docker compose..."
    if docker compose version &>/dev/null; then
        skip "docker compose $(docker compose version --short 2>/dev/null || echo '?') already installed"
    else
        install "docker compose should have been installed with docker-compose-plugin"
        pkg_install docker-compose-plugin
    fi

    # [3/4] Add current user to docker group
    echo "[3/4] docker group..."
    if groups | grep -q docker; then
        skip "user $(whoami) already in docker group"
    else
        install "adding $(whoami) to docker group"
        sudo usermod -aG docker "$(whoami)"
        echo "  NOTE: log out and back in for group change to take effect"
    fi

    # [4/4] Daemon config
    echo "[4/4] daemon.json..."
    DAEMON_CFG="/etc/docker/daemon.json"
    if [[ -f "$DAEMON_CFG" ]]; then
        skip "$DAEMON_CFG already exists (not overwriting)"
        echo "  Review template: $REPO_DIR/configs/docker-daemon.json"
    else
        install "deploying optimized daemon.json"
        sudo mkdir -p /etc/docker
        sudo cp "$REPO_DIR/configs/docker-daemon.json" "$DAEMON_CFG"
        sudo systemctl restart docker 2>/dev/null || true
    fi

else
    echo "Unsupported OS: $OS (Docker setup supports Linux and macOS only)" >&2
    exit 1
fi

echo ""
echo "=== Docker setup complete ==="
echo ""
if is_macos; then
    echo "Installed: Docker Desktop"
else
    echo "Installed: Docker Engine, Docker Compose, BuildX"
fi
echo ""
echo "Test with: docker run hello-world"
