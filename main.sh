#!/bin/bash
set -euo pipefail

# Kickstart
# Author: Dusan Panic <dpanic@gmail.com>
# https://github.com/dpanic/ubuntu-kickstart
#
# Interactive TUI launcher using Charmbracelet's gum
# Supports Ubuntu (apt) and macOS (brew)

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
LOG_DIR="$REPO_DIR/logs"
mkdir -p "$LOG_DIR"

source "$SCRIPTS_DIR/lib.sh"

# ─── Bootstrap gum ───────────────────────────────────────────────────────────

ensure_gum() {
    if command -v gum &>/dev/null; then
        return
    fi

    echo "gum not found -- installing Charmbracelet gum..."
    if is_macos; then
        ensure_brew
        brew install gum
    else
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://repo.charm.sh/apt/gpg.key \
            | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
        echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
            | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
        sudo apt-get update -qq
        sudo apt-get install -y gum
    fi
    echo ""
}

ensure_gum

# ─── Colors & styles ─────────────────────────────────────────────────────────

ACCENT="212"       # pink
ACCENT2="39"       # cyan
BORDER="rounded"
OK_COLOR="78"      # green
WARN_COLOR="208"   # orange

# ─── Banner ──────────────────────────────────────────────────────────────────

show_banner() {
    local title subtitle author banner

    title=$(gum style \
        --foreground "$ACCENT" \
        --bold \
        "  Kickstart")

    subtitle=$(gum style \
        --foreground "$ACCENT2" \
        --faint \
        "  System optimization & dev environment setup")

    author=$(gum style \
        --faint \
        "  by Dusan Panic <dpanic@gmail.com>")

    banner=$(printf "%s\n%s\n%s" "$title" "$subtitle" "$author")

    gum style \
        --border "$BORDER" \
        --border-foreground "$ACCENT" \
        --padding "1 3" \
        --margin "1 0" \
        "$banner"
}

# ─── Item registry ───────────────────────────────────────────────────────────
# Format: "os|script|component|label"
#   os: "all", "linux", or "macos"
#   component empty = standalone script
#   component set   = sub-item of a grouped script

ALL_ITEMS=(
    "linux|gnome-optimize.sh||GNOME Optimize -- disable animations, sounds, hot corners"
    "linux|nautilus-optimize.sh||Nautilus Optimize -- restrict Tracker, limit thumbnails"
    "linux|apparmor-setup.sh||AppArmor Setup -- learning mode with Slack reminder"
    "all|install-shell-tools.sh|zsh|Shell ▸ zsh + oh-my-zsh"
    "all|install-shell-tools.sh|fzf|Shell ▸ fzf (fuzzy finder)"
    "all|install-shell-tools.sh|starship|Shell ▸ starship prompt"
    "all|install-shell-tools.sh|direnv|Shell ▸ direnv"
    "all|install-shell-tools.sh|plugins|Shell ▸ zsh plugins (autosuggestions, syntax-highlighting)"
    "all|install-shell-tools.sh|nvm|Shell ▸ nvm (Node version manager)"
    "all|install-shell-tools.sh|git|Shell ▸ git config (LFS, SSH-over-HTTPS)"
    "linux|install-terminal-tools.sh|byobu|Terminal ▸ byobu + tmux"
    "all|install-terminal-tools.sh|ncdu|Terminal ▸ ncdu (disk analyzer)"
    "all|install-docker.sh||Docker -- engine, compose, buildx, daemon config"
    "all|install-yazi.sh||Yazi -- terminal file manager"
    "all|install-neovim.sh||Neovim + LazyVim -- editor with IDE features"
    "linux|install-peazip.sh||PeaZip -- archive manager (200+ formats)"
)

build_items() {
    ITEMS=()
    for entry in "${ALL_ITEMS[@]}"; do
        local item_os="${entry%%|*}"
        local rest="${entry#*|}"
        if [[ "$item_os" == "all" ]] || [[ "$item_os" == "$OS" ]]; then
            ITEMS+=("$rest")
        fi
    done
}

build_items

get_labels() {
    for entry in "${ITEMS[@]}"; do
        local label="${entry#*|}"
        echo "${label#*|}"
    done
}

# ─── Selection parser ────────────────────────────────────────────────────────
# Turns selected labels into ordered (script, components) pairs

declare -A SCRIPT_COMPONENTS
SCRIPT_ORDER=()

parse_selection() {
    SCRIPT_COMPONENTS=()
    SCRIPT_ORDER=()

    while IFS= read -r label; do
        [[ -z "$label" ]] && continue

        for entry in "${ITEMS[@]}"; do
            local e_label="${entry#*|}"
            e_label="${e_label#*|}"
            if [[ "$e_label" == "$label" ]]; then
                local script="${entry%%|*}"
                local rest="${entry#*|}"
                local component="${rest%%|*}"

                if [[ -z "${SCRIPT_COMPONENTS[$script]+_}" ]]; then
                    SCRIPT_ORDER+=("$script")
                    SCRIPT_COMPONENTS["$script"]=""
                fi

                if [[ -n "$component" ]]; then
                    SCRIPT_COMPONENTS["$script"]+="$component "
                fi
                break
            fi
        done
    done
}

# ─── User profile ────────────────────────────────────────────────────────────

collect_user_info() {
    local needs_info=false

    for script in "${SCRIPT_ORDER[@]}"; do
        case "$script" in
            install-shell-tools.sh|install-docker.sh|apparmor-setup.sh)
                local comps="${SCRIPT_COMPONENTS[$script]}"
                if [[ "$script" == "install-shell-tools.sh" && -n "$comps" && "$comps" != *git* ]]; then
                    continue
                fi
                needs_info=true
                ;;
        esac
    done

    if [[ "$needs_info" != true ]]; then
        return
    fi

    local existing_name existing_email
    existing_name=$(git config --global user.name 2>/dev/null || true)
    existing_email=$(git config --global user.email 2>/dev/null || true)

    echo ""
    gum style --foreground "$ACCENT" --bold "  Setup info"
    gum style --faint "  Used for git config. Leave blank to skip."
    echo ""

    export KICKSTART_USER_NAME
    KICKSTART_USER_NAME=$(gum input \
        --prompt "  Full name: " \
        --value "${existing_name:-}" \
        --placeholder "Dusan Panic" \
        --prompt.foreground "$ACCENT") || true

    export KICKSTART_USER_EMAIL
    KICKSTART_USER_EMAIL=$(gum input \
        --prompt "  Email:     " \
        --value "${existing_email:-}" \
        --placeholder "you@example.com" \
        --prompt.foreground "$ACCENT") || true

    if [[ -n "$KICKSTART_USER_NAME" && -n "$KICKSTART_USER_EMAIL" ]]; then
        echo ""
        gum style --foreground "$OK_COLOR" \
            "  → $KICKSTART_USER_NAME <$KICKSTART_USER_EMAIL>"
    fi
}

# ─── Run selected scripts ────────────────────────────────────────────────────

run_scripts() {
    local ran=0
    local failed=0
    local results=()

    for script in "${SCRIPT_ORDER[@]}"; do
        local components="${SCRIPT_COMPONENTS[$script]}"
        components="${components% }"   # trim trailing space

        local script_path="$SCRIPTS_DIR/$script"
        [[ ! -x "$script_path" ]] && chmod +x "$script_path"

        local logfile="$LOG_DIR/${script%.sh}-$(date +%Y%m%d-%H%M%S).log"

        echo ""
        gum style --foreground "$ACCENT2" --bold "━━━ Running: $script ━━━"
        if [[ -n "$components" ]]; then
            gum style --faint "  components: $components"
        fi
        echo ""

        local rc=0
        if [[ "$script" == "apparmor-setup.sh" ]]; then
            local webhook
            webhook=$(gum input \
                --prompt "Slack webhook URL: " \
                --placeholder "https://hooks.slack.com/services/T.../B.../xxx" \
                --prompt.foreground "$ACCENT" < /dev/tty) || true
            if [[ -z "$webhook" ]]; then
                echo "  Skipped (no webhook URL provided)"
                results+=("$(gum style --foreground "$WARN_COLOR" "  ⊘ $script (skipped)")")
                continue
            fi
            sudo bash "$script_path" "$webhook" 2>&1 | tee "$logfile" || rc=${PIPESTATUS[0]}
        else
            # shellcheck disable=SC2086
            bash "$script_path" $components 2>&1 | tee "$logfile" || rc=${PIPESTATUS[0]}
        fi

        if [[ $rc -eq 0 ]]; then
            ran=$((ran + 1))
            results+=("$(gum style --foreground "$OK_COLOR" "  ✓ $script")")
        else
            failed=$((failed + 1))
            results+=("$(gum style --foreground 196 "  ✗ $script (exit $rc)")")
        fi
    done

    echo ""
    local summary
    summary=$(printf "%s\n\n%s\n\n%s\n\n%s" \
        "$(gum style --foreground "$ACCENT" --bold '  Results')" \
        "$(printf '%s\n' "${results[@]}")" \
        "$(gum style --faint "  $ran succeeded, $failed failed")" \
        "$(gum style --faint "  Logs: $LOG_DIR/")")

    gum style \
        --border "$BORDER" \
        --border-foreground "$OK_COLOR" \
        --padding "1 2" \
        --margin "1 0" \
        "$summary"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    clear
    show_banner

    local chosen
    chosen=$(get_labels \
        | gum choose \
            --no-limit \
            --height 20 \
            --cursor-prefix "[▸] " \
            --selected-prefix "[✓] " \
            --unselected-prefix "[ ] " \
            --cursor.foreground "$ACCENT" \
            --selected.foreground "$ACCENT2" \
            --header "SPACE = toggle  ·  ENTER = confirm" \
            --header.foreground "$ACCENT") || true

    if [[ -z "$chosen" ]]; then
        gum style --foreground "$WARN_COLOR" "  Nothing selected. Exiting."
        exit 0
    fi

    parse_selection <<< "$chosen"

    local count=${#SCRIPT_ORDER[@]}

    collect_user_info

    echo ""
    if gum confirm --prompt.foreground "$ACCENT" "Run $count script(s)?"; then
        run_scripts
    else
        gum style --foreground "$WARN_COLOR" "  Cancelled."
    fi
}

main "$@"
