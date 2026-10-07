#!/usr/bin/env bash
# Build arm64 Firecracker guest Image + initdisk on the Vera box.
# Artifacts are NOT in git. This is the self-contained path when eng has not
# staged a tarball.
#
# Typed:  ./o k
#
# Requires: ~/rlp already cloned (./o g got that far), sudo, network for kernel.org.
set -euo pipefail

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

RLP_ROOT="${RLP_ROOT:-${HOME}/rlp}"
GUEST_DIR="${GUEST_DIR:-/var/lib/rlp/kernel}"
JOBS="${RLP_JOBS:-$(nproc)}"

log() { printf '[oci-guest] %s\n' "$*"; }
die() { printf '[oci-guest] ERROR: %s\n' "$*" >&2; exit 1; }

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then "$@"
  elif sudo -n true 2>/dev/null; then sudo "$@"
  else die "need passwordless sudo"
  fi
}

[[ -d "${RLP_ROOT}/guest/kernel" ]] || die "missing ${RLP_ROOT}/guest (clone RLP first: ./o g)"

log "apt: busybox-static e2fsprogs build-essential bc flex bison libssl-dev libelf-dev"
export DEBIAN_FRONTEND=noninteractive
as_root apt-get update -qq
as_root apt-get install -y -qq \
  busybox-static e2fsprogs build-essential bc flex bison \
  libssl-dev libelf-dev dwarves >/dev/null

as_root mkdir -p "${GUEST_DIR}"
as_root chown -R "${USER}:${USER}" /var/lib/rlp

# --- kernel Image ---
KERNEL_OUT="${GUEST_DIR}/Image-6.12.34-rlp1-arm64"
if [[ -f "${KERNEL_OUT}" ]]; then
  log "kernel already present: ${KERNEL_OUT}"
else
  log "building arm64 guest kernel (-j${JOBS}) — often 5–20 min on Vera"
  (
    cd "${RLP_ROOT}/guest"
    RLP_ARCH=arm64 \
    RLP_NFS_KERNEL="${GUEST_DIR}" \
    RLP_JOBS="${JOBS}" \
    bash kernel/build-kernel.sh \
      --config config-6.12.34-rlp1-arm64 \
      --label rlp1 \
      --install
  )
  # build-kernel installs Image-6.12.34-rlp1 into GUEST_DIR
  if [[ ! -f "${KERNEL_OUT}" ]]; then
    # tolerate slight name variance
    found="$(ls -1 "${GUEST_DIR}"/Image-6.12.34* 2>/dev/null | head -n1 || true)"
    [[ -n "${found}" ]] || die "kernel build finished but Image not in ${GUEST_DIR}"
    cp -f "${found}" "${KERNEL_OUT}"
  fi
  # short alias the bootstrap resolver also looks for
  ln -sfn "${KERNEL_OUT}" "${GUEST_DIR}/Image-arm64"
fi

# --- initdisk ---
INITDISK_OUT="${GUEST_DIR}/initdisk-arm64.ext4"
if [[ -f "${INITDISK_OUT}" ]]; then
  log "initdisk already present: ${INITDISK_OUT}"
else
  log "building initdisk"
  BUSYBOX="$(command -v busybox || true)"
  [[ -x "${BUSYBOX}" ]] || die "busybox not on PATH after apt install"
  INIT_SRC="${RLP_ROOT}/guest/init"
  [[ -f "${INIT_SRC}" ]] || die "missing ${INIT_SRC}"
  ROOT="$(mktemp -d)"
  mkdir -p "${ROOT}/bin" "${ROOT}/proc" "${ROOT}/sys" "${ROOT}/dev" "${ROOT}/mnt" "${ROOT}/overlay"
  cp "${BUSYBOX}" "${ROOT}/bin/busybox"
  cp "${INIT_SRC}" "${ROOT}/init"
  chmod +x "${ROOT}/init" "${ROOT}/bin/busybox"
  ln -sf busybox "${ROOT}/bin/sh"
  rm -f "${INITDISK_OUT}"
  dd if=/dev/zero of="${INITDISK_OUT}" bs=1M count=16 status=none
  mkfs.ext4 -q -F -L initdisk -d "${ROOT}" "${INITDISK_OUT}"
  rm -rf "${ROOT}"
  log "initdisk -> ${INITDISK_OUT} ($(stat -c%s "${INITDISK_OUT}") bytes)"
fi

log "done"
ls -lh "${GUEST_DIR}/Image-arm64" "${KERNEL_OUT}" "${INITDISK_OUT}"
echo
echo "Next: ./o g"
