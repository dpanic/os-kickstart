#!/bin/bash
set -euo pipefail

# Ubuntu 24.04 Nautilus / File Manager Optimization
# Author: Dusan Panic <dpanic@gmail.com>
# Restricts Tracker indexing, limits thumbnails, clears stale cache
# Safe to re-run -- idempotent

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_DIR/lib.sh"
parse_update_flag "$@"

if [[ "$UNINSTALL" == true ]]; then
    echo "=== Nautilus Optimization -- Revert ==="
    echo ""
    echo "[1/2] Restoring Tracker to index recursively from HOME..."
    gsettings reset org.freedesktop.Tracker3.Miner.Files index-recursive-directories 2>/dev/null || true
    systemctl --user restart tracker-miner-fs-3.service 2>/dev/null || true
    echo "  done."

    echo "[2/2] Restoring default thumbnail settings..."
    gsettings reset org.gnome.nautilus.preferences show-image-thumbnails 2>/dev/null || true
    dconf reset /org/gnome/nautilus/preferences/thumbnail-limit 2>/dev/null || true
    gsettings reset org.gnome.nautilus.preferences search-filter-time-type 2>/dev/null || true
    echo "  done."

    echo ""
    echo "=== Nautilus revert complete ==="
    exit 0
fi

TRACKER_DIRS="['&DESKTOP', '&DOCUMENTS', '&MUSIC', '&PICTURES', '&VIDEOS']"
THUMBNAIL_LIMIT=1048576  # 1MB

echo "=== Nautilus / File Manager Optimization ==="
echo ""

echo "[1/4] Restricting Tracker indexed directories..."
echo "  Excluding: \$HOME (recursive), Downloads"
echo "  Keeping:   Desktop, Documents, Music, Pictures, Videos"
gsettings set org.freedesktop.Tracker3.Miner.Files index-recursive-directories "$TRACKER_DIRS"
echo "  done."

echo "[2/4] Clearing Tracker index and restarting..."
tracker3 reset -s -r 2>/dev/null || true
systemctl --user restart tracker-miner-fs-3.service 2>/dev/null || true
echo "  done."

echo "[3/4] Configuring Nautilus thumbnails..."
gsettings set org.gnome.nautilus.preferences show-image-thumbnails 'local-only'
dconf write /org/gnome/nautilus/preferences/thumbnail-limit "uint64 $THUMBNAIL_LIMIT"
gsettings set org.gnome.nautilus.preferences search-filter-time-type 'last_modified'
echo "  thumbnails: local-only, max $(( THUMBNAIL_LIMIT / 1024 ))KB"
echo "  done."

echo "[4/4] Clearing thumbnail cache..."
CACHE_SIZE=$(du -sh ~/.cache/thumbnails/ 2>/dev/null | cut -f1 || echo "0")
rm -rf ~/.cache/thumbnails/*
echo "  freed: $CACHE_SIZE"
echo "  done."

echo ""
echo "=== Nautilus optimization complete ==="
echo ""
echo "Current Tracker indexed dirs:"
gsettings get org.freedesktop.Tracker3.Miner.Files index-recursive-directories | sed 's/^/  /'
