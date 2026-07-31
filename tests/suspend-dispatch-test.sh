#!/usr/bin/env bash
# Exercises fake suspend and device-gated deep suspend without systemd or hardware.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH="$ROOT/system_files/usr/libexec/armada/suspend-dispatch"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

make_device_env() {
    local suspend_mode=$1
    local mem_sleep_mode=$2

    {
        printf '#!/bin/bash\n'
        printf 'printf "ARMADA_SUSPEND_MODE=%%q\\\\n" %q\n' "$suspend_mode"
        printf 'printf "ARMADA_MEM_SLEEP_MODE=%%q\\\\n" %q\n' "$mem_sleep_mode"
    } >"$tmp/device-env"
    chmod +x "$tmp/device-env"
}

make_recorder() {
    local path=$1
    local record=$2

    {
        printf '#!/bin/bash\n'
        printf 'printf "%%s\\\\n" "$*" >%q\n' "$record"
    } >"$path"
    chmod +x "$path"
}

make_recorder "$tmp/fake-suspend" "$tmp/fake-called"
make_recorder "$tmp/systemd-sleep" "$tmp/systemd-called"

make_device_env fake ""
printf '[s2idle] deep\n' >"$tmp/mem_sleep"
ARMADA_DEVICE_ENV_BIN="$tmp/device-env" \
ARMADA_FAKE_SUSPEND_BIN="$tmp/fake-suspend" \
ARMADA_MEM_SLEEP_PATH="$tmp/mem_sleep" \
ARMADA_SYSTEMD_SLEEP_BIN="$tmp/systemd-sleep" \
    "$DISPATCH"
[[ "$(<"$tmp/fake-called")" == sleep ]]
[[ ! -e "$tmp/systemd-called" ]]
[[ "$(<"$tmp/mem_sleep")" == "[s2idle] deep" ]]

make_device_env mem deep
ARMADA_DEVICE_ENV_BIN="$tmp/device-env" \
ARMADA_FAKE_SUSPEND_BIN="$tmp/fake-suspend" \
ARMADA_MEM_SLEEP_PATH="$tmp/mem_sleep" \
ARMADA_SYSTEMD_SLEEP_BIN="$tmp/systemd-sleep" \
    "$DISPATCH"
[[ "$(<"$tmp/systemd-called")" == suspend ]]
[[ "$(<"$tmp/mem_sleep")" == deep ]]

printf '[s2idle]\n' >"$tmp/mem_sleep"
if ARMADA_DEVICE_ENV_BIN="$tmp/device-env" \
    ARMADA_MEM_SLEEP_PATH="$tmp/mem_sleep" \
    ARMADA_SYSTEMD_SLEEP_BIN="$tmp/systemd-sleep" \
    "$DISPATCH" 2>"$tmp/unavailable-error"; then
    printf 'deep suspend unexpectedly fell back when unavailable\n' >&2
    exit 1
fi
grep -q 'deep is unavailable' "$tmp/unavailable-error"

printf 'suspend dispatch test passed\n'
