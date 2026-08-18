#!/usr/bin/env bash
# Pin performance + cap at nominal; boost stays 1 or PPD per-policy boost writes EINVAL.

kickstart_cpu_sysfs() { printf '%s\n' "${KICKSTART_SYSFS:-/sys}"; }

# Portable/laptop/tablet/convertible — skip the pin (heat + battery).
kickstart_cpu_is_laptop() {
    [[ "${KICKSTART_CPU_GOVERNOR:-}" == "force" ]] && return 1
    local t
    t=$(cat "$(kickstart_cpu_sysfs)/class/dmi/id/chassis_type" 2>/dev/null || echo 0)
    case "$t" in
        8|9|10|14|30|31|32) return 0 ;;
        *) return 1 ;;
    esac
}

# ACPI CPPC nominal_freq is MHz; Intel base_frequency is already kHz.
kickstart_cpu_preboost_max_khz() {
    local policy="$1"
    local n cppc
    n="${policy##*policy}"
    cppc="$(kickstart_cpu_sysfs)/devices/system/cpu/cpu${n}/acpi_cppc/nominal_freq"
    if [[ -f "$cppc" ]]; then
        local mhz
        mhz=$(<"$cppc")
        if [[ "$mhz" -gt 0 ]]; then
            echo $((mhz * 1000))
            return
        fi
    fi
    if [[ -f "$policy/base_frequency" ]]; then
        cat "$policy/base_frequency"
        return
    fi
    echo 0
}

kickstart_cpu_cap_max_khz() {
    local policy="$1"
    local pre hw cur
    pre=$(kickstart_cpu_preboost_max_khz "$policy")
    hw=$(<"$policy/cpuinfo_max_freq")
    cur=$(<"$policy/scaling_max_freq")
    if [[ "$pre" -gt 0 ]]; then
        echo "$pre"
        return
    fi
    if [[ "$cur" -lt "$hw" ]]; then
        echo "$cur"
        return
    fi
    echo "$cur"
}

kickstart_cpu_min_khz() {
    local policy="$1" max="$2"
    local min
    if [[ -f "$policy/amd_pstate_lowest_nonlinear_freq" ]]; then
        min=$(<"$policy/amd_pstate_lowest_nonlinear_freq")
    else
        min=$(<"$policy/cpuinfo_min_freq")
    fi
    if [[ "$min" -gt "$max" ]]; then
        min=$max
    fi
    echo "$min"
}

# sysfs rejects a write that would make min > max at any instant.
kickstart_cpu_write_range() {
    local policy="$1" min="$2" max="$3"
    local cur_min
    cur_min=$(<"$policy/scaling_min_freq")
    if [[ "$max" -lt "$cur_min" ]]; then
        printf '%s\n' "$min" >"$policy/scaling_min_freq"
        printf '%s\n' "$max" >"$policy/scaling_max_freq"
    else
        printf '%s\n' "$max" >"$policy/scaling_max_freq"
        printf '%s\n' "$min" >"$policy/scaling_min_freq"
    fi
}

kickstart_cpu_apply() {
    local sysfs pol max min boost
    sysfs=$(kickstart_cpu_sysfs)
    if [[ ! -d "$sysfs/devices/system/cpu/cpufreq" ]]; then
        echo "no cpufreq sysfs, skip"
        return 0
    fi
    if kickstart_cpu_is_laptop; then
        echo "laptop chassis, skip CPU pin (KICKSTART_CPU_GOVERNOR=force to override)"
        return 0
    fi
    if [[ -z "${KICKSTART_SYSFS:-}" ]] && command -v powerprofilesctl >/dev/null 2>&1; then
        powerprofilesctl set performance >/dev/null 2>&1 || true
    fi
    boost="$sysfs/devices/system/cpu/cpufreq/boost"
    if [[ -f "$boost" ]]; then
        printf '1\n' >"$boost" || true
    fi
    for pol in "$sysfs/devices/system/cpu/cpufreq"/policy*; do
        [[ -e "$pol/scaling_governor" ]] || continue
        max=$(kickstart_cpu_cap_max_khz "$pol")
        min=$(kickstart_cpu_min_khz "$pol" "$max")
        kickstart_cpu_write_range "$pol" "$min" "$max"
        if grep -qw performance "$pol/scaling_available_governors" 2>/dev/null; then
            printf 'performance\n' >"$pol/scaling_governor"
        fi
    done
}

kickstart_cpu_revert() {
    local sysfs pol
    sysfs=$(kickstart_cpu_sysfs)
    for pol in "$sysfs/devices/system/cpu/cpufreq"/policy*; do
        [[ -e "$pol/scaling_governor" ]] || continue
        if grep -qw powersave "$pol/scaling_available_governors" 2>/dev/null; then
            printf 'powersave\n' >"$pol/scaling_governor"
        fi
        kickstart_cpu_write_range "$pol" "$(<"$pol/cpuinfo_min_freq")" "$(<"$pol/cpuinfo_max_freq")"
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    if [[ "${EUID}" -ne 0 && -z "${KICKSTART_SYSFS:-}" ]]; then
        echo "Error: must be run as root" >&2
        exit 1
    fi
    case "${1:-}" in
        revert|stop) kickstart_cpu_revert ;;
        *) kickstart_cpu_apply ;;
    esac
fi
