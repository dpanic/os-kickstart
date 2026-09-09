#!/usr/bin/env bash
# Reproduce the cursor stutter under load and measure it, instead of eyeballing it.
#
#   ./stutter-test.sh [seconds]        default 120
#
# Move the mouse continuously across BOTH monitors for the whole window.
# Everything here is read-only apart from the load it generates.
set -uo pipefail

DUR=${1:-120}
SHELL_PID=$(pgrep -u "$(id -u)" -x gnome-shell | head -1)
if [[ -z "$SHELL_PID" ]]; then
    echo "gnome-shell not found -- run this inside the graphical session" >&2
    exit 1
fi
INPUT_TID=$(for t in /proc/"$SHELL_PID"/task/*; do
    grep -qx 'Mutter Input Th' "$t/comm" 2>/dev/null && basename "$t"
done)

softnet_squeeze() { awk '{t+=strtonum("0x"$3)} END{print t+0}' /proc/net/softnet_stat; }
# libinput rate-limits this warning to 5/hour/device, so the count is a floor.
# Count the suppression notices too or a capped hour reads as a quiet one.
lag_count()  { journalctl -b --since "@$1" --no-pager 2>/dev/null | grep -c 'lagging behind'; }
rate_limited() { journalctl -b --since "@$1" --no-pager 2>/dev/null | grep -c 'rate limit'; }

echo "=== stutter test: ${DUR}s, ${NPROC:=$(nproc)} threads ==="
echo "shell=$SHELL_PID input_tid=$INPUT_TID"
echo
echo ">>> MOVE THE MOUSE CONTINUOUSLY ACROSS BOTH MONITORS FOR THE WHOLE RUN <<<"
echo

T0=$(date +%s)
SQ0=$(softnet_squeeze)
SCHED0=$(awk '{print $2}' /proc/"$SHELL_PID"/task/"$INPUT_TID"/schedstat)

# CPU burn on every thread plus a memory-bandwidth stream -- the page-table and
# cache pressure is what made the old fork stall scale with load.
pids=()
for _ in $(seq "$NPROC"); do
    ( while :; do :; done ) & pids+=($!)
done
( while :; do dd if=/dev/zero of=/dev/null bs=1M count=4096 status=none; done ) & pids+=($!)

trap 'kill "${pids[@]}" 2>/dev/null' EXIT INT TERM
sleep "$DUR"
kill "${pids[@]}" 2>/dev/null
wait 2>/dev/null
trap - EXIT INT TERM

SQ1=$(softnet_squeeze)
SCHED1=$(awk '{print $2}' /proc/"$SHELL_PID"/task/"$INPUT_TID"/schedstat)
sleep 2   # let journald flush

echo
echo "=== results over ${DUR}s under full load ==="
printf '  libinput "lagging behind" : %s   (rate-limit notices: %s)\n' "$(lag_count "$T0")" "$(rate_limited "$T0")"
printf '  softnet time_squeeze      : %s\n' "$((SQ1 - SQ0))"
printf '  input thread runqueue wait: %s ms\n' "$(( (SCHED1 - SCHED0) / 1000000 ))"
echo
echo "How to read it:"
echo "  libinput count 0 and runqueue wait small  -> the input path stayed healthy"
echo "  libinput count > 0                        -> still stalling; capture the cause with:"
echo "     sudo bpftrace -e 'kprobe:dup_mmap /pid==$SHELL_PID/ { @s[tid]=nsecs; }"
echo "       kretprobe:dup_mmap /@s[tid]/ { printf(\"%s %d us\\n\", strftime(\"%H:%M:%S.%f\", nsecs),"
echo "       (nsecs-@s[tid])/1000); delete(@s[tid]); }'"
echo "  time_squeeze rising is NOT a regression -- it counts softirq rounds that yielded,"
echo "  which is exactly what lowering netdev_budget_usecs was meant to make them do."
