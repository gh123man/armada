#!/bin/bash
set -euo pipefail

FIRMWARE_ROOT="${FIRMWARE_ROOT:-/usr/lib/firmware}"
ODIN2_DIR="${FIRMWARE_ROOT}/qcom/sm8550/ayn/odin2"
RP6_PARENT="${FIRMWARE_ROOT}/qcom/sm8550/retroidpocket"
RP6_DIR="${RP6_PARENT}/rp6"

# The RP6 currently uses the same ADSP and speaker-amplifier firmware as the
# Odin 2. Keep the device-specific kernel path so native RP6 firmware can
# replace this compatibility link later without another DTB change.
if [[ ! -e "${RP6_DIR}" && ! -L "${RP6_DIR}" ]]; then
    mkdir -p "${RP6_PARENT}"
    ln -s ../ayn/odin2 "${RP6_DIR}"
fi

for required in \
    adsp.mbn \
    adsp_dtb.mbn \
    adspr.jsn \
    adsps.jsn \
    adspua.jsn \
    aw883xx_acf.bin \
    battmgr.jsn; do
    if [[ ! -r "${RP6_DIR}/${required}" ]]; then
        echo "ERROR: RP6 firmware missing: ${RP6_DIR}/${required}" >&2
        echo "       compatibility source: ${ODIN2_DIR}/${required}" >&2
        exit 1
    fi
done
