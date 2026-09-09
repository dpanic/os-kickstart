#!/bin/bash
# Table-driven tests for fix-netdev-budget.sh.
#
# The login discovery cannot be integration-tested from here: on every host reachable
# from this machine the plain ssh_config/agent path already works, so the candidate loop
# short-circuits before it is exercised. What the loop decides is therefore pinned here
# with try_login stubbed, and the ordering is the part that matters -- a backup key that
# still authenticates somewhere must never be chosen over the live one.
set -uo pipefail

SRC="$(dirname "${BASH_SOURCE[0]}")/fix-netdev-budget.sh"
# shellcheck source=fix-netdev-budget.sh
source "$SRC"
[[ $(type -t discover_login) == function ]] || {
    echo "cannot load discover_login from $SRC"
    exit 1
}

fail=0
check() {
    if [[ "$1" == "$2" ]]; then
        echo "  ok   $3"
    else
        echo "  FAIL $3 (want=$1 got=$2)"
        fail=1
    fi
}

# Stub: ACCEPT holds the one "user|key" pair the imaginary host accepts. TRIED records
# every attempt in order, so the tests can assert what was tried and in what sequence.
TRIED=()
ACCEPT=""
try_login() {
    local u="$1" k="$2"
    TRIED+=("$u|$k")
    [[ "$u|$k" == "$ACCEPT" ]]
}

setup_home() {
    HOME=$(mktemp -d)
    mkdir -p "$HOME/.ssh"
    for f in "$@"; do
        printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nstub\n' >"$HOME/.ssh/$f"
    done
    printf 'ssh-ed25519 AAAA stub\n' >"$HOME/.ssh/site-vms.pub"
    printf 'host ssh-ed25519 AAAA\n'  >"$HOME/.ssh/known_hosts"
    printf 'Host *\n'                 >"$HOME/.ssh/config"
}

ORIG_HOME="$HOME"
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT
restore() { HOME="$ORIG_HOME"; SSH_USER=""; SSH_KEY=""; TRIED=(); ACCEPT=""; }

# Never $(discover_login ...): command substitution forks, and the TRIED array the
# assertions read would be mutated in the subshell and lost.
run_discover() { discover_login "$1" >"$OUT" 2>&1; }

echo "TEST 1 -- a working ssh_config/agent is never second-guessed"
restore; setup_home site-vms
ACCEPT="|"
run_discover probe
out=$(cat "$OUT")
check 1 "${#TRIED[@]}" "stops after the first attempt"
check "|" "${TRIED[0]:-<none>}" "that attempt is bare ssh, no -i and no user"
check "" "$SSH_KEY" "no key pinned"
case "$out" in *"ssh-agent"*) echo "  ok   reports the agent/config path" ;;
               *) echo "  FAIL reports the agent/config path (got: $out)"; fail=1 ;; esac

echo "TEST 2 -- a site key is found when the default does not authenticate"
restore; setup_home site-vms
ACCEPT="user|$HOME/.ssh/site-vms"
run_discover probe
check "user" "$SSH_USER" "discovers the account"
check "$HOME/.ssh/site-vms" "$SSH_KEY" "discovers the key"

echo "TEST 3 -- backup keys are tried only after live ones"
restore; setup_home site-vms other-vms.bak-20260101
ACCEPT="user|$HOME/.ssh/other-vms.bak-20260101"
run_discover probe
live_pos=-1; bak_pos=-1
for i in "${!TRIED[@]}"; do
    [[ "${TRIED[$i]}" == *"/site-vms" && $live_pos -lt 0 ]] && live_pos=$i
    [[ "${TRIED[$i]}" == *".bak-20260101" && $bak_pos -lt 0 ]] && bak_pos=$i
done
check true "$([ "$live_pos" -lt "$bak_pos" ] && echo true || echo false)" \
    "live key tried before the backup"
check "$HOME/.ssh/other-vms.bak-20260101" "$SSH_KEY" "backup still usable as a last resort"

echo "TEST 4 -- keys one level deep (~/.ssh/old/) are found too"
restore; setup_home site-vms
mkdir -p "$HOME/.ssh/old"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nstub\n' >"$HOME/.ssh/old/id_ed25519"
ACCEPT="user|$HOME/.ssh/old/id_ed25519"
run_discover probe
check "$HOME/.ssh/old/id_ed25519" "$SSH_KEY" "nested key discovered"

echo "TEST 5 -- .pub, known_hosts and config are never offered as identities"
restore; setup_home site-vms
ACCEPT="nobody|nothing"
run_discover probe
bad=0
for t in "${TRIED[@]}"; do
    case "${t#*|}" in *.pub|*known_hosts*|*/config) bad=1 ;; esac
done
check 0 "$bad" "no non-key file was passed to ssh -i"

echo "TEST 6 -- an explicit --user narrows the search instead of widening it"
restore; setup_home site-vms
SSH_USER="squid"; ACCEPT="squid|$HOME/.ssh/site-vms"
run_discover probe
other=0
for t in "${TRIED[@]}"; do
    case "$t" in squid\|*) ;; *) other=1 ;; esac
done
check 0 "$other" "only the requested account is attempted"

echo "TEST 7 -- nothing authenticates: report it, do not pin a random key"
restore; setup_home site-vms
ACCEPT="nobody|nothing"
run_discover probe
out=$(cat "$OUT")
check "" "$SSH_KEY" "no key pinned"
case "$out" in *"nothing authenticated"*) echo "  ok   says so out loud" ;;
               *) echo "  FAIL says so out loud (got: $out)"; fail=1 ;; esac

restore
echo
[[ $fail -eq 0 ]] && echo "PASS" || echo "FAIL"
exit $fail
