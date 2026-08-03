#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

ODIN2_DIR="${TEST_ROOT}/qcom/sm8550/ayn/odin2"
RP6_DIR="${TEST_ROOT}/qcom/sm8550/retroidpocket/rp6"

mkdir -p "${ODIN2_DIR}"
for firmware in \
    adsp.mbn \
    adsp_dtb.mbn \
    adspr.jsn \
    adsps.jsn \
    adspua.jsn \
    aw883xx_acf.bin \
    battmgr.jsn; do
    printf 'test firmware\n' >"${ODIN2_DIR}/${firmware}"
done

FIRMWARE_ROOT="${TEST_ROOT}" \
    bash "${REPO_ROOT}/build_files/ensure-rp6-firmware.sh"

[[ -L "${RP6_DIR}" ]]
[[ "$(readlink "${RP6_DIR}")" == "../ayn/odin2" ]]
[[ -r "${RP6_DIR}/adsp.mbn" ]]
[[ -r "${RP6_DIR}/aw883xx_acf.bin" ]]
[[ -r "${RP6_DIR}/battmgr.jsn" ]]

rm "${ODIN2_DIR}/adsp.mbn"
if FIRMWARE_ROOT="${TEST_ROOT}" \
    bash "${REPO_ROOT}/build_files/ensure-rp6-firmware.sh" >/dev/null 2>&1; then
    echo "RP6 firmware validation accepted a missing ADSP image" >&2
    exit 1
fi

printf 'RP6 firmware layout test passed\n'
