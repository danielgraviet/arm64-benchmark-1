#!/usr/bin/env bash
# Build amd64 Firecracker guest Image/vmlinux + initdisk on the Zen5 box.
# Separate from scripts/host/oci_build_guest.sh (leave that arm64/Vera-only).
#
# Typed:  cd amd && ./o k
#
# Requires: ~/rlp already cloned (./o start got that far), sudo, network.
set -euo pipefail

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RLP_ROOT="${RLP_ROOT:-${HOME}/rlp}"
GUEST_DIR="${GUEST_DIR:-/var/lib/rlp/kernel}"
JOBS="${RLP_JOBS:-$(nproc)}"

log() { printf '[zen5-guest] %s\n' "$*"; }
die() { printf '[zen5-guest] ERROR: %s\n' "$*" >&2; exit 1; }

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then "$@"
  elif sudo -n true 2>/dev/null; then sudo "$@"
  else die "need passwordless sudo"
  fi
}

[[ "$(uname -m)" == "x86_64" ]] || die "expected x86_64 host"
[[ -d "${RLP_ROOT}/guest/kernel" ]] || die "missing ${RLP_ROOT}/guest (clone RLP first: ./o start)"

log "apt: busybox-static e2fsprogs build-essential bc flex bison libssl-dev libelf-dev"
export DEBIAN_FRONTEND=noninteractive
as_root apt-get update -qq
as_root apt-get install -y -qq \
  busybox-static e2fsprogs build-essential bc flex bison \
  libssl-dev libelf-dev dwarves >/dev/null

as_root mkdir -p "${GUEST_DIR}"
as_root chown -R "${USER}:${USER}" /var/lib/rlp

pick_kernel_config() {
  if [[ -n "${RLP_KERNEL_CONFIG:-}" ]]; then
    printf '%s' "${RLP_KERNEL_CONFIG}"
    return
  fi
  local cfg_dir="${RLP_ROOT}/guest/kernel"
  local cand
  for cand in \
    config-6.12.34-rlp1-amd64 \
    config-6.12.34-rlp1-x86_64 \
    config-6.12.34-rlp1-x86 \
    config-amd64 \
    config-x86_64; do
    if [[ -f "${cfg_dir}/${cand}" ]]; then
      printf '%s' "${cand}"
      return
    fi
  done
  # Fall back to any *amd64* / *x86* config in the tree.
  cand="$(ls -1 "${cfg_dir}"/config*amd64* "${cfg_dir}"/config*x86* 2>/dev/null | head -n1 || true)"
  if [[ -n "${cand}" ]]; then
    printf '%s' "$(basename "${cand}")"
    return
  fi
  log "available configs under ${cfg_dir}:"
  ls -1 "${cfg_dir}"/config* 2>/dev/null || true
  die "no amd64/x86 guest kernel config found. Set RLP_KERNEL_CONFIG=…"
}

# --- kernel ---
KERNEL_OUT="${GUEST_DIR}/vmlinux-6.12.34-rlp1-amd64"
IMAGE_ALIAS="${GUEST_DIR}/vmlinux-amd64"
if [[ -f "${KERNEL_OUT}" || -f "${IMAGE_ALIAS}" ]]; then
  log "kernel already present under ${GUEST_DIR}"
  [[ -f "${KERNEL_OUT}" ]] || KERNEL_OUT="$(ls -1 "${GUEST_DIR}"/vmlinux*amd64* "${GUEST_DIR}"/Image*amd64* 2>/dev/null | head -n1)"
else
  CFG="$(pick_kernel_config)"
  log "building amd64 guest kernel with ${CFG} (-j${JOBS})"
  (
    cd "${RLP_ROOT}/guest"
    RLP_ARCH=amd64 \
    RLP_NFS_KERNEL="${GUEST_DIR}" \
    RLP_JOBS="${JOBS}" \
    bash kernel/build-kernel.sh \
      --config "${CFG}" \
      --label rlp1 \
      --install
  )
  if [[ ! -f "${KERNEL_OUT}" ]]; then
    found="$(ls -1 "${GUEST_DIR}"/vmlinux* "${GUEST_DIR}"/Image* 2>/dev/null | head -n1 || true)"
    [[ -n "${found}" ]] || die "kernel build finished but Image/vmlinux not in ${GUEST_DIR}"
    cp -f "${found}" "${KERNEL_OUT}"
  fi
  ln -sfn "${KERNEL_OUT}" "${IMAGE_ALIAS}"
  # Also alias Image-amd64 for resolvers that look for Image-* names.
  ln -sfn "${KERNEL_OUT}" "${GUEST_DIR}/Image-amd64"
fi

# --- initdisk ---
INITDISK_OUT="${GUEST_DIR}/initdisk-amd64.ext4"
if [[ -f "${INITDISK_OUT}" ]]; then
  log "initdisk already present: ${INITDISK_OUT}"
else
  log "building initdisk"
  BUSYBOX="$(command -v busybox || true)"
  [[ -x "${BUSYBOX}" ]] || die "busybox not on PATH after apt install"
  INIT_SRC="${RLP_ROOT}/guest/init"
  [[ -f "${INIT_SRC}" ]] || die "missing ${INIT_SRC}"
  ROOTFS="$(mktemp -d)"
  mkdir -p "${ROOTFS}/bin" "${ROOTFS}/proc" "${ROOTFS}/sys" "${ROOTFS}/dev" "${ROOTFS}/mnt" "${ROOTFS}/overlay"
  cp "${BUSYBOX}" "${ROOTFS}/bin/busybox"
  cp "${INIT_SRC}" "${ROOTFS}/init"
  chmod +x "${ROOTFS}/init" "${ROOTFS}/bin/busybox"
  ln -sf busybox "${ROOTFS}/bin/sh"
  rm -f "${INITDISK_OUT}"
  dd if=/dev/zero of="${INITDISK_OUT}" bs=1M count=16 status=none
  mkfs.ext4 -q -F -L initdisk -d "${ROOTFS}" "${INITDISK_OUT}"
  rm -rf "${ROOTFS}"
  log "initdisk -> ${INITDISK_OUT} ($(stat -c%s "${INITDISK_OUT}") bytes)"
fi

log "done"
ls -lh "${IMAGE_ALIAS}" "${KERNEL_OUT}" "${INITDISK_OUT}" 2>/dev/null \
  || ls -lh "${GUEST_DIR}"/vmlinux* "${GUEST_DIR}"/Image* "${INITDISK_OUT}" 2>/dev/null || true
echo
echo "Next: cd $(cd "${SCRIPT_DIR}/.." && pwd) && ./o start"
