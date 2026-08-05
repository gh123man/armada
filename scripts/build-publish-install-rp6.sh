#!/usr/bin/env bash
# Build the current armada-packages kernel and Armada bootc images, publish
# CI-style images to GHCR, and stage the exact Armada digest on a Retroid
# Pocket 6. The device is never rebooted. A newly-created Podman machine is
# removed after a successful push.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PACKAGES_DIR="${ARMADA_PACKAGES_DIR:-${REPO_DIR}/../armada-packages}"
DEVICE="${ARMADA_HOST:-armada@192.168.1.83}"
REGISTRY="${ARMADA_REGISTRY:-ghcr.io/gh123man/armada}"
KERNEL_REGISTRY="${ARMADA_KERNEL_REGISTRY:-ghcr.io/gh123man/armada-packages/kernel}"
MACHINE="${ARMADA_PODMAN_MACHINE:-armada-builder}"
LOCAL_REPOSITORY="localhost/armada"
MACHINE_CPUS="${ARMADA_BUILD_CPUS:-8}"
MACHINE_MEMORY_MIB="${ARMADA_BUILD_MEMORY_MIB:-12288}"
MACHINE_DISK_GIB="${ARMADA_BUILD_DISK_GIB:-120}"
MIN_HOST_FREE_GIB="${ARMADA_MIN_HOST_FREE_GIB:-45}"
MIN_VM_FREE_GIB="${ARMADA_MIN_VM_FREE_GIB:-40}"
MIN_DEVICE_FREE_GIB="${ARMADA_MIN_DEVICE_FREE_GIB:-15}"

TAG="${ARMADA_IMAGE_TAG:-}"
KERNEL_TAG="${ARMADA_KERNEL_IMAGE_TAG:-}"

DO_BUILD=1
DO_PUSH=1
DO_INSTALL=1
KEEP_MACHINE=0
CREATED_MACHINE=0
PUSHED=0
DIGEST="${ARMADA_IMAGE_DIGEST:-}"

usage() {
    cat <<'EOF'
Usage: scripts/build-publish-install-rp6.sh [options]

Builds a kernel carrier from the current armada-packages branch, builds and
rechunks a full arm64 Armada bootc image like CI, pushes both to GHCR, and
stages the pushed Armada digest on an RP6 without rebooting.

Options:
  --tag TAG             Image tag (default: deep-sleep-<armada>-<packages>)
  --registry IMAGE      Registry repository (default: ghcr.io/gh123man/armada)
  --kernel-registry IMG Kernel registry repository
  --device USER@HOST    RP6 SSH destination
  --packages-dir DIR    armada-packages checkout
  --skip-build          Reuse the local image in the Podman machine
  --skip-push           Do not publish (requires --digest to install)
  --skip-install        Build and publish only
  --digest SHA256       Exact published digest for an install-only resume
  --keep-machine        Keep a newly-created Podman machine after success
  -h, --help            Show this help

Authentication:
  Publishing uses ARMADA_GHCR_TOKEN, then GITHUB_TOKEN, then `gh auth token`.
  SSH and sudo may prompt for the device password. The GHCR package must be
  public for device-side import.
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

free_kib() {
    df -Pk "$1" | awk 'NR == 2 { print $4 }'
}

require_free_gib() {
    label="$1"
    path="$2"
    minimum_gib="$3"
    available_kib="$(free_kib "${path}")"
    minimum_kib=$((minimum_gib * 1024 * 1024))
    if (( available_kib < minimum_kib )); then
        die "${label} has less than ${minimum_gib} GiB free"
    fi
    echo "==> ${label}: $((available_kib / 1024 / 1024)) GiB free"
}

safe_tag() {
    [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]
}

safe_image() {
    [[ "$1" =~ ^[A-Za-z0-9._/:@+-]+$ ]]
}

while (( $# > 0 )); do
    case "$1" in
        --tag)
            (( $# >= 2 )) || die "--tag requires a value"
            TAG="$2"
            shift 2
            ;;
        --registry)
            (( $# >= 2 )) || die "--registry requires a value"
            REGISTRY="$2"
            shift 2
            ;;
        --kernel-registry)
            (( $# >= 2 )) || die "--kernel-registry requires a value"
            KERNEL_REGISTRY="$2"
            shift 2
            ;;
        --device)
            (( $# >= 2 )) || die "--device requires a value"
            DEVICE="$2"
            shift 2
            ;;
        --packages-dir)
            (( $# >= 2 )) || die "--packages-dir requires a value"
            PACKAGES_DIR="$2"
            shift 2
            ;;
        --skip-build)
            DO_BUILD=0
            shift
            ;;
        --skip-push)
            DO_PUSH=0
            shift
            ;;
        --skip-install)
            DO_INSTALL=0
            shift
            ;;
        --digest)
            (( $# >= 2 )) || die "--digest requires a value"
            DIGEST="$2"
            shift 2
            ;;
        --keep-machine)
            KEEP_MACHINE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

if [[ -z "${TAG}" ]]; then
    ARMADA_REV="$(git -C "${REPO_DIR}" rev-parse --short HEAD)"
    PACKAGES_REV="$(git -C "${PACKAGES_DIR}" rev-parse --short HEAD)"
    TAG="deep-sleep-${ARMADA_REV}-${PACKAGES_REV}"
fi
if [[ -z "${KERNEL_TAG}" ]]; then
    PACKAGES_REV="$(git -C "${PACKAGES_DIR}" rev-parse --short HEAD)"
    KERNEL_TAG="$(date -u +%Y%m%d)-${PACKAGES_REV:0:8}"
fi

safe_tag "${TAG}" || die "unsafe image tag: ${TAG}"
safe_tag "${KERNEL_TAG}" || die "unsafe kernel image tag: ${KERNEL_TAG}"
safe_image "${REGISTRY}" || die "unsafe registry image: ${REGISTRY}"
safe_image "${KERNEL_REGISTRY}" || die "unsafe kernel registry image: ${KERNEL_REGISTRY}"
[[ "${DEVICE}" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._:-]+$ ]] || die "unsafe SSH destination: ${DEVICE}"
[[ -d "${PACKAGES_DIR}/kernel" ]] || die "missing packages checkout: ${PACKAGES_DIR}"
[[ -z "${DIGEST}" || "${DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid digest: ${DIGEST}"
if (( DO_INSTALL == 1 && DO_PUSH == 0 )) && [[ -z "${DIGEST}" ]]; then
    die "--skip-push with installation requires --digest"
fi

LOCAL_IMAGE="${LOCAL_REPOSITORY}:${TAG}"
REMOTE_IMAGE="${REGISTRY}:${TAG}"
LOCAL_KERNEL_IMAGE="localhost/armada-packages/kernel:latest"
REMOTE_KERNEL_IMAGE="${KERNEL_REGISTRY}:${KERNEL_TAG}"
ROOTFUL_CHUNKED_IMAGE="localhost/armada-chunked:${TAG}"

cleanup_machine_after_push() {
    if (( CREATED_MACHINE == 1 && PUSHED == 1 && KEEP_MACHINE == 0 )); then
        echo "==> Removing disposable Podman machine ${MACHINE}"
        podman machine stop "${MACHINE}" >/dev/null 2>&1 || true
        podman machine rm -f "${MACHINE}" >/dev/null
    elif (( CREATED_MACHINE == 1 && PUSHED == 0 )); then
        echo "==> Preserving ${MACHINE} because the image was not pushed" >&2
        echo "    Resume with: $0 --tag '${TAG}' --skip-build" >&2
    fi
}
trap cleanup_machine_after_push EXIT

start_builder() {
    require_free_gib "Mac build volume" "${REPO_DIR}" "${MIN_HOST_FREE_GIB}"

    if ! podman machine inspect "${MACHINE}" >/dev/null 2>&1; then
        echo "==> Creating disposable Podman machine ${MACHINE}"
        podman machine init \
            --cpus "${MACHINE_CPUS}" \
            --memory "${MACHINE_MEMORY_MIB}" \
            --disk-size "${MACHINE_DISK_GIB}" \
            "${MACHINE}"
        CREATED_MACHINE=1
    fi

    state="$(podman machine inspect --format '{{.State}}' "${MACHINE}")"
    if [[ "${state}" != "running" && "${state}" != "Running" ]]; then
        echo "==> Starting Podman machine ${MACHINE}"
        podman machine start "${MACHINE}"
    fi

    if (( CREATED_MACHINE == 1 )); then
        podman machine ssh "${MACHINE}" touch /var/tmp/.armada-disposable-builder
    elif podman machine ssh "${MACHINE}" test -f /var/tmp/.armada-disposable-builder; then
        CREATED_MACHINE=1
    fi

    vm_free_kib="$(podman machine ssh "${MACHINE}" df -Pk /var | \
        awk 'NR == 2 { print $4 }')"
    vm_minimum_kib=$((MIN_VM_FREE_GIB * 1024 * 1024))
    if (( vm_free_kib < vm_minimum_kib )); then
        die "Podman VM has less than ${MIN_VM_FREE_GIB} GiB free in /var"
    fi
    echo "==> Podman VM: $((vm_free_kib / 1024 / 1024)) GiB free in /var"
}

build_image() {
    package_branch="$(git -C "${PACKAGES_DIR}" branch --show-current)"
    package_commit="$(git -C "${PACKAGES_DIR}" rev-parse HEAD)"
    echo "==> Building kernel from ${PACKAGES_DIR}"
    echo "    branch: ${package_branch:-detached HEAD}"
    echo "    commit: ${package_commit}"
    (
        cd "${PACKAGES_DIR}"
        just image kernel
    )

    kernel_artifact="$(find "${PACKAGES_DIR}/kernel/out" -maxdepth 1 \
        -type f -name 'armada-kernel-*.tar.zst' -print | sort | tail -n 1)"
    [[ -n "${kernel_artifact}" && -f "${kernel_artifact}.sha256" ]] || \
        die "kernel build did not produce a checksummed artifact"
    (
        cd "$(dirname "${kernel_artifact}")"
        shasum -a 256 -c "$(basename "${kernel_artifact}.sha256")"
    )
    podman image exists "${LOCAL_KERNEL_IMAGE}" || \
        die "kernel carrier was not built: ${LOCAL_KERNEL_IMAGE}"

    echo "==> Building ${LOCAL_IMAGE}"
    (
        cd "${REPO_DIR}"
        ARMADA_LOCAL_PKGS=kernel just build "${LOCAL_REPOSITORY}" "${TAG}"
    )

    echo "==> Validating firmware layout, version, architecture, and bootc metadata"
    podman run --rm --entrypoint bash "${LOCAL_IMAGE}" -lc '
        set -euo pipefail
        test "$(uname -m)" = aarch64
        test "$(readlink -f /usr/lib/firmware/qcom/sm8550/retroidpocket/rp6)" = \
            /usr/lib/firmware/qcom/sm8550/ayn/odin2
        test -r /usr/lib/firmware/qcom/sm8550/retroidpocket/rp6/adsp.mbn
        test -r /usr/lib/firmware/qcom/sm8550/retroidpocket/rp6/adsp_dtb.mbn
        test -r /usr/lib/firmware/qcom/sm8550/retroidpocket/rp6/aw883xx_acf.bin
        cat /usr/lib/armada/version
    '
    podman run --rm "${LOCAL_IMAGE}" bootc container lint
}

load_ghcr_token() {
    GHCR_TOKEN="${ARMADA_GHCR_TOKEN:-${GITHUB_TOKEN:-}}"
    if [[ -z "${GHCR_TOKEN}" ]]; then
        GHCR_TOKEN="$(gh auth token 2>/dev/null)" || \
            die "GitHub authentication is unavailable; run 'gh auth login -h github.com'"
    fi
    REGISTRY_PATH="${REGISTRY#ghcr.io/}"
    REGISTRY_USER="${REGISTRY_PATH%%/*}"
}

publish_kernel_image() {
    echo "==> Publishing kernel carrier built from the current packages branch"
    printf '%s' "${GHCR_TOKEN}" | podman login ghcr.io -u "${REGISTRY_USER}" \
        --password-stdin >/dev/null
    podman tag "${LOCAL_KERNEL_IMAGE}" "${REMOTE_KERNEL_IMAGE}"
    podman tag "${LOCAL_KERNEL_IMAGE}" "${KERNEL_REGISTRY}:latest"
    podman push "${REMOTE_KERNEL_IMAGE}"
    kernel_digest_file="$(mktemp /tmp/armada-kernel-digest.XXXXXX)"
    podman push --digestfile "${kernel_digest_file}" "${KERNEL_REGISTRY}:latest"
    KERNEL_DIGEST="$(tr -d '[:space:]' <"${kernel_digest_file}")"
    rm -f "${kernel_digest_file}"
    [[ "${KERNEL_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || \
        die "kernel push returned an invalid digest"
    echo "==> Published ${REMOTE_KERNEL_IMAGE}@${KERNEL_DIGEST}"
}

rechunk_image() {
    raw_archive="/var/tmp/armada-raw-${TAG}.tar"
    rootful_raw="localhost/armada-raw:${TAG}"
    rootful_chunked="${ROOTFUL_CHUNKED_IMAGE}"

    echo "==> Rechunking Armada image for small OTA deltas (matching repository CI)"
    podman machine ssh "${MACHINE}" \
        "skopeo copy 'containers-storage:${LOCAL_IMAGE}' 'oci-archive:${raw_archive}'"
    podman machine ssh "${MACHINE}" \
        "sudo skopeo copy 'oci-archive:${raw_archive}' 'containers-storage:${rootful_raw}'"

    # Match CI's peak-space reduction: delete the archive and rootless raw tag
    # once the rootful copy is complete, before creating the chunked image.
    podman machine ssh "${MACHINE}" rm -f "${raw_archive}"
    podman rmi "${LOCAL_IMAGE}" >/dev/null
    podman image prune -f >/dev/null

    podman machine ssh "${MACHINE}" \
        "sudo podman run --rm --privileged \
          --volume /var/lib/containers:/var/lib/containers \
          '${rootful_raw}' \
          rpm-ostree compose build-chunked-oci --bootc --max-layers 127 \
          --format-version 2 --from '${rootful_raw}' \
          --output 'containers-storage:${rootful_chunked}'"
    podman machine ssh "${MACHINE}" \
        "sudo podman run --rm '${rootful_chunked}' bootc container lint"
}

publish_image() {
    load_ghcr_token
    publish_kernel_image
    if podman machine ssh "${MACHINE}" \
        sudo podman image exists "${ROOTFUL_CHUNKED_IMAGE}"; then
        echo "==> Reusing existing rechunked image ${ROOTFUL_CHUNKED_IMAGE}"
    else
        rechunk_image
    fi

    echo "==> Logging rootful CI-style storage in to ghcr.io"
    printf '%s' "${GHCR_TOKEN}" | podman machine ssh "${MACHINE}" \
        sudo skopeo login ghcr.io -u "${REGISTRY_USER}" --password-stdin >/dev/null

    echo "==> Pushing rechunked ${REMOTE_IMAGE}"
    attempt=0
    until podman machine ssh "${MACHINE}" \
        "sudo skopeo copy 'containers-storage:${ROOTFUL_CHUNKED_IMAGE}' 'docker://${REMOTE_IMAGE}'"; do
        attempt=$((attempt + 1))
        (( attempt < 3 )) || die "failed to push ${REMOTE_IMAGE} after 3 attempts"
        echo "Push failed; retrying (${attempt}/3)" >&2
    done
    DIGEST="$(podman machine ssh "${MACHINE}" \
        "sudo skopeo inspect --format '{{.Digest}}' 'docker://${REMOTE_IMAGE}'")"
    DIGEST="$(printf '%s' "${DIGEST}" | tr -d '[:space:]')"
    [[ "${DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "push returned an invalid digest"
    unset GHCR_TOKEN
    PUSHED=1
    echo "==> Published ${REMOTE_IMAGE}@${DIGEST}"
}

install_image() {
    work_dir="$(mktemp -d /tmp/armada-rp6-install.XXXXXX)"
    control_socket="${work_dir}/ssh-control"
    remote_dir="/var/tmp/armada-image-install-${TAG}"

    cleanup_install() {
        ssh -S "${control_socket}" -O exit "${DEVICE}" >/dev/null 2>&1 || true
        rm -rf "${work_dir}"
    }
    trap 'cleanup_install; cleanup_machine_after_push' EXIT

    cat >"${work_dir}/policy.json" <<'EOF'
{"default":[{"type":"insecureAcceptAnything"}]}
EOF
    cat >"${work_dir}/install.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
remote_dir="$1"
remote_ref="$2"
digest="$3"
tag="$4"
minimum_free_gib="$5"
destination="localhost/armada:${tag}"
staged_policy="${remote_dir}/policy.json"
policy="/run/armada-image-install-policy-${tag}.json"

cleanup() {
    sudo rm -f "${policy}" >/dev/null 2>&1 || true
    rm -f "${staged_policy}" "${remote_dir}/install.sh"
    rmdir "${remote_dir}" 2>/dev/null || true
}
trap cleanup EXIT

[[ "${remote_dir}" == /var/tmp/armada-image-install-* ]]
[[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]
[[ "${tag}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]
[[ "$(tr -d '\0' </proc/device-tree/model)" == "Retroid Pocket 6" ]]
grep -Fqx 'retroidpocket,rp6' < <(tr '\0' '\n' </proc/device-tree/compatible)
command -v skopeo >/dev/null

available_kib="$(df -Pk /var | awk 'NR == 2 { print $4 }')"
minimum_kib=$((minimum_free_gib * 1024 * 1024))
(( available_kib >= minimum_kib )) || {
    echo "Device has less than ${minimum_free_gib} GiB free in /var" >&2
    exit 1
}

echo "==> Current device state"
sudo bootc status
sudo ostree admin status

# Preserve the known-good rollback when the currently booted deployment is a
# test image. bootc switch may otherwise rotate the rollback out of the list.
if ! sudo bootc status --json | grep -q '"rollback".*"pinned":true'; then
    echo "==> Pinning existing rollback deployment before staging"
    sudo ostree admin pin 1
fi

echo "==> Importing exact published digest into rootful container storage"
sudo install -m 0600 "${staged_policy}" "${policy}"
sudo skopeo copy --policy "${policy}" \
    "docker://${remote_ref}@${digest}" \
    "containers-storage:${destination}"

imported_digest="$(sudo podman image inspect --format '{{.Digest}}' "${destination}")"
[[ "${imported_digest}" == "${digest}" ]] || {
    echo "Imported digest ${imported_digest} does not match ${digest}" >&2
    exit 1
}

sudo bootc switch --transport containers-storage "${destination}"
sudo bootc status
sudo ostree admin status
echo "Staged ${destination}@${digest}; the RP6 has not been rebooted."
EOF
    chmod 0755 "${work_dir}/install.sh"

    ssh_options=(
        -o ControlMaster=auto
        -o ControlPersist=90
        -o ConnectTimeout=10
        -o ServerAliveInterval=10
        -o ServerAliveCountMax=2
        -o "ControlPath=${control_socket}"
    )
    echo "==> Opening SSH connection to ${DEVICE}"
    ssh "${ssh_options[@]}" "${DEVICE}" true
    ssh "${ssh_options[@]}" "${DEVICE}" "mkdir -p '${remote_dir}'"
    scp "${ssh_options[@]}" "${work_dir}/policy.json" "${work_dir}/install.sh" \
        "${DEVICE}:${remote_dir}/"
    # Skopeo on the RP6 rejects Docker references containing both a tag and a
    # digest. Pass the repository without a tag and let the immutable digest
    # select the exact image that was just published.
    ssh -tt "${ssh_options[@]}" "${DEVICE}" \
        "bash '${remote_dir}/install.sh' '${remote_dir}' '${REGISTRY}' '${DIGEST}' '${TAG}' '${MIN_DEVICE_FREE_GIB}'"

    cleanup_install
    trap cleanup_machine_after_push EXIT
}

need_command git
need_command shasum
need_command ssh
need_command scp
(( DO_PUSH == 0 )) || need_command gh
if (( DO_BUILD == 1 || DO_PUSH == 1 )); then
    need_command podman
fi
if (( DO_BUILD == 1 )); then
    need_command just
fi

if (( DO_BUILD == 1 || DO_PUSH == 1 )); then
    start_builder
fi
if (( DO_BUILD == 1 )); then
    build_image
elif (( DO_PUSH == 1 )); then
    if ! podman image exists "${LOCAL_IMAGE}" && \
        ! podman machine ssh "${MACHINE}" \
            sudo podman image exists "${ROOTFUL_CHUNKED_IMAGE}"; then
        die "missing raw and rechunked images for tag: ${TAG}"
    fi
fi
if (( DO_PUSH == 1 )); then
    publish_image
fi
if (( DO_INSTALL == 1 )); then
    install_image
fi

echo "==> Complete"
echo "    kernel: ${REMOTE_KERNEL_IMAGE}@${KERNEL_DIGEST:-not-pushed}"
echo "    image: ${REMOTE_IMAGE}@${DIGEST}"
echo "    reboot: not performed"
