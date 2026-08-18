#!/bin/bash
# Table-driven tests for cpu-governor.sh against a fake sysfs tree.
set -uo pipefail

SRC="$(dirname "${BASH_SOURCE[0]}")/cpu-governor.sh"
# shellcheck source=cpu-governor.sh
source "$SRC"
[[ $(type -t kickstart_cpu_preboost_max_khz) == function ]] || {
    echo "cannot load kickstart_cpu_preboost_max_khz from $SRC"
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

make_policy() {
    local root="$1" n="$2"
    local pol="$root/devices/system/cpu/cpufreq/policy${n}"
    local cpu="$root/devices/system/cpu/cpu${n}"
    mkdir -p "$pol" "$cpu/acpi_cppc" "$root/devices/system/cpu/cpufreq" "$root/class/dmi/id"
    printf '%s\n' "$3" >"$pol/cpuinfo_min_freq"
    printf '%s\n' "$4" >"$pol/cpuinfo_max_freq"
    printf '%s\n' "$5" >"$pol/scaling_min_freq"
    printf '%s\n' "$6" >"$pol/scaling_max_freq"
    printf '%s\n' "performance powersave" >"$pol/scaling_available_governors"
    printf '%s\n' "powersave" >"$pol/scaling_governor"
}

echo "TEST 1 -- AMD CPPC nominal_freq is the pre-boost cap (MHz -> kHz)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
make_policy "$tmp" 0 414795 5737986 414795 5737986
printf '4701\n' >"$tmp/devices/system/cpu/cpu0/acpi_cppc/nominal_freq"
printf '3007258\n' >"$tmp/devices/system/cpu/cpufreq/policy0/amd_pstate_lowest_nonlinear_freq"
printf '1\n' >"$tmp/devices/system/cpu/cpufreq/boost"
printf '3\n' >"$tmp/class/dmi/id/chassis_type"
KICKSTART_SYSFS="$tmp"
check 4701000 "$(kickstart_cpu_preboost_max_khz "$tmp/devices/system/cpu/cpufreq/policy0")" "nominal 4701 MHz"
check 3007258 "$(kickstart_cpu_min_khz "$tmp/devices/system/cpu/cpufreq/policy0" 4701000)" "lowest_nonlinear min"

echo "TEST 2 -- Intel base_frequency is the pre-boost cap"
tmp2=$(mktemp -d)
make_policy "$tmp2" 0 800000 4900000 800000 4900000
printf '3500000\n' >"$tmp2/devices/system/cpu/cpufreq/policy0/base_frequency"
KICKSTART_SYSFS="$tmp2"
check 3500000 "$(kickstart_cpu_preboost_max_khz "$tmp2/devices/system/cpu/cpufreq/policy0")" "base_frequency kHz"
check 800000 "$(kickstart_cpu_min_khz "$tmp2/devices/system/cpu/cpufreq/policy0" 3500000)" "cpuinfo_min when no nonlinear"

echo "TEST 3 -- unknown pre-boost: keep a tighter existing cap, never raise to turbo"
tmp3=$(mktemp -d)
make_policy "$tmp3" 0 400000 5000000 400000 4000000
KICKSTART_SYSFS="$tmp3"
check 0 "$(kickstart_cpu_preboost_max_khz "$tmp3/devices/system/cpu/cpufreq/policy0")" "no cppc/base -> 0"
check 4000000 "$(kickstart_cpu_cap_max_khz "$tmp3/devices/system/cpu/cpufreq/policy0")" "keep existing cap"

echo "TEST 4 -- laptop chassis skipped unless forced"
tmp4=$(mktemp -d)
make_policy "$tmp4" 0 414795 5737986 414795 5737986
printf '10\n' >"$tmp4/class/dmi/id/chassis_type"
KICKSTART_SYSFS="$tmp4"
unset KICKSTART_CPU_GOVERNOR || true
kickstart_cpu_is_laptop
check 0 "$?" "chassis 10 is laptop"
KICKSTART_CPU_GOVERNOR=force
kickstart_cpu_is_laptop
check 1 "$?" "force overrides laptop"

echo "TEST 5 -- apply pins governor, cap, boost; revert restores range"
tmp5=$(mktemp -d)
make_policy "$tmp5" 0 414795 5737986 414795 5737986
make_policy "$tmp5" 1 414795 5737986 414795 5737986
printf '4701\n' >"$tmp5/devices/system/cpu/cpu0/acpi_cppc/nominal_freq"
printf '4701\n' >"$tmp5/devices/system/cpu/cpu1/acpi_cppc/nominal_freq"
printf '3007258\n' >"$tmp5/devices/system/cpu/cpufreq/policy0/amd_pstate_lowest_nonlinear_freq"
printf '3007258\n' >"$tmp5/devices/system/cpu/cpufreq/policy1/amd_pstate_lowest_nonlinear_freq"
printf '0\n' >"$tmp5/devices/system/cpu/cpufreq/boost"
printf '3\n' >"$tmp5/class/dmi/id/chassis_type"
KICKSTART_SYSFS="$tmp5"
unset KICKSTART_CPU_GOVERNOR || true
kickstart_cpu_apply
check 1 "$(cat "$tmp5/devices/system/cpu/cpufreq/boost")" "boost enabled"
check performance "$(cat "$tmp5/devices/system/cpu/cpufreq/policy0/scaling_governor")" "governor pinned"
check 4701000 "$(cat "$tmp5/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" "max = nominal, not turbo"
check 3007258 "$(cat "$tmp5/devices/system/cpu/cpufreq/policy0/scaling_min_freq")" "min = lowest_nonlinear"
check performance "$(cat "$tmp5/devices/system/cpu/cpufreq/policy1/scaling_governor")" "policy1 governor"
kickstart_cpu_revert
check powersave "$(cat "$tmp5/devices/system/cpu/cpufreq/policy0/scaling_governor")" "revert governor"
check 414795 "$(cat "$tmp5/devices/system/cpu/cpufreq/policy0/scaling_min_freq")" "revert min"
check 5737986 "$(cat "$tmp5/devices/system/cpu/cpufreq/policy0/scaling_max_freq")" "revert max = turbo range"

echo "TEST 6 -- laptop apply is a no-op"
tmp6=$(mktemp -d)
make_policy "$tmp6" 0 414795 5737986 414795 5737986
printf '9\n' >"$tmp6/class/dmi/id/chassis_type"
printf '0\n' >"$tmp6/devices/system/cpu/cpufreq/boost"
printf 'powersave\n' >"$tmp6/devices/system/cpu/cpufreq/policy0/scaling_governor"
KICKSTART_SYSFS="$tmp6"
unset KICKSTART_CPU_GOVERNOR || true
kickstart_cpu_apply
check powersave "$(cat "$tmp6/devices/system/cpu/cpufreq/policy0/scaling_governor")" "laptop leaves governor"
check 0 "$(cat "$tmp6/devices/system/cpu/cpufreq/boost")" "laptop leaves boost"

echo
[[ $fail -eq 0 ]] && echo "PASS" || echo "FAIL"
exit $fail
