#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
device_env="$root/system_files/usr/libexec/armada/device-env"
device_quirks="$root/system_files/usr/libexec/armada/device-quirks"
device_dir="$root/system_files/usr/lib/armada/devices"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p \
    "$tmp/sys/devices/system/cpu/cpu0/cpuidle/state1" \
    "$tmp/etc/NetworkManager"
disable="$tmp/sys/devices/system/cpu/cpu0/cpuidle/state1/disable"

run_quirks() {
    local model=$1

    ARMADA_DEVICE_ENV_BIN="$device_env" \
    ARMADA_DEVICE_DIR="$device_dir" \
    ARMADA_MODEL="$model" \
    ARMADA_SYSFS_ROOT="$tmp/sys" \
    ARMADA_ETC_ROOT="$tmp/etc" \
        "$device_quirks"
}

printf '1\n' >"$disable"
touch "$tmp/etc/NetworkManager/ignore-sleep"
run_quirks 'Retroid Pocket 6'
[[ "$(<"$disable")" == 0 ]] || {
    echo 'RP6 did not keep CPU0 state1 enabled' >&2
    exit 1
}
[[ ! -e "$tmp/etc/NetworkManager/ignore-sleep" ]] || {
    echo 'RP6 real suspend did not remove the NetworkManager sleep override' >&2
    exit 1
}

printf '0\n' >"$disable"
run_quirks 'AYN Thor'
[[ "$(<"$disable")" == 1 ]] || {
    echo 'Thor no longer applies the SM8550 GMU workaround' >&2
    exit 1
}

printf 'device quirk tests passed\n'
