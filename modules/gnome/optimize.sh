#!/bin/bash
set -euo pipefail

# Ubuntu 24.04 GNOME Desktop Optimization
# Author: Dusan Panic <dpanic@gmail.com>
# Disables animations, unnecessary sounds, and non-essential extensions
# Safe to re-run -- idempotent

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_DIR/lib.sh"
parse_update_flag "$@"

if [[ "$UNINSTALL" == true ]]; then
    echo "=== GNOME Optimization -- Revert ==="
    echo ""
    echo "[1/2] Re-enabling animations, sounds, hot corners..."
    gsettings set org.gnome.desktop.interface enable-animations true
    gsettings set org.gnome.desktop.sound event-sounds true
    gsettings set org.gnome.desktop.interface enable-hot-corners true
    echo "  done."

    echo "[2/2] Re-enabling all GNOME extensions..."
    ALL_EXTENSIONS=$(gnome-extensions list 2>/dev/null)
    while IFS= read -r ext; do
        [[ -z "$ext" ]] && continue
        gnome-extensions enable "$ext" 2>/dev/null && echo "  enabled: $ext" || true
    done <<< "$ALL_EXTENSIONS"

    echo ""
    echo "=== GNOME revert complete ==="
    exit 0
fi

KEEP_EXTENSIONS=(
    "ubuntu-dock@ubuntu.com"
    "ubuntu-appindicators@ubuntu.com"
    "tiling-assistant@ubuntu.com"
    "ding@rastersoft.com"
    "system-monitor@gnome-shell-extensions.gcampax.github.com"
    "launch-new-instance@gnome-shell-extensions.gcampax.github.com"
    # Canonical defaults introduced on Ubuntu 25.10/26.04 -- keep enabled
    "snapd-prompting@canonical.com"
    "snapd-search-provider@canonical.com"
    "web-search-provider@ubuntu.com"
)

echo "=== GNOME Desktop Optimization ==="
echo ""

echo "[1/3] Disabling animations, event sounds, hot corners..."
gsettings set org.gnome.desktop.interface enable-animations false
gsettings set org.gnome.desktop.sound event-sounds false
gsettings set org.gnome.desktop.interface enable-hot-corners false
echo "  done."

echo "[2/3] Disabling non-essential GNOME extensions..."
ALL_EXTENSIONS=$(gnome-extensions list 2>/dev/null)

is_kept() {
    local ext="$1"
    for keep in "${KEEP_EXTENSIONS[@]}"; do
        [[ "$ext" == "$keep" ]] && return 0
    done
    return 1
}

disabled_count=0
while IFS= read -r ext; do
    [[ -z "$ext" ]] && continue
    if ! is_kept "$ext"; then
        if gnome-extensions disable "$ext" 2>/dev/null; then
            echo "  disabled: $ext"
            # NB: $(( )) assignment, not ((var++)) -- the latter returns exit 1
            # when the pre-increment value is 0 and trips `set -e`.
            disabled_count=$((disabled_count + 1))
        fi
    else
        echo "  kept:     $ext"
    fi
done <<< "$ALL_EXTENSIONS"
echo "  $disabled_count extensions disabled."

echo "[3/3] Ensuring kept extensions are enabled..."
for ext in "${KEEP_EXTENSIONS[@]}"; do
    gnome-extensions enable "$ext" 2>/dev/null && echo "  enabled: $ext" || true
done

echo ""
echo "=== GNOME optimization complete ==="
echo "Note: some changes take full effect after GNOME Shell reload (log out/in)."
echo ""
echo "Enabled extensions:"
gnome-extensions list --enabled 2>/dev/null | sed 's/^/  /'
