#!/usr/bin/env bash
# Build the arm64 Daytona daemon and publish it as the guest system layer.
# Firecracker can boot without this; the toolbox on :2280 cannot.
#
# Typed: ./o a
set -euo pipefail

export PATH="${HOME}/.local/bin:/usr/local/go/bin:${PATH}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"

RLP_ROOT="${RLP_ROOT:-${HOME}/rlp}"
CAS_ROOT="${CAS_ROOT:-/var/lib/rlp/cas}"
# v0.190.0 is the public daytonaio/daytona tag. The "-rlp6" suffix is the
# patched build label, not a GitHub tag (tarball 404).
VERSION="${RLP_DAEMON_VERSION:-v0.190.0}"

log() { printf '[oci-daemon] %s\n' "$*"; }
die() { printf '[oci-daemon] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -x "${RLP_ROOT}/tools/daemon/build-daemon.sh" ]] || die "missing ${RLP_ROOT} (./o g first)"
command -v go >/dev/null || die "go not on PATH"
command -v mkfs.erofs >/dev/null || die "mkfs.erofs missing (apt install erofs-utils)"

sudo -n mkdir -p "${CAS_ROOT}/system" "${CAS_ROOT}/layers/sha256"
sudo -n chown -R "${USER}:${USER}" /var/lib/rlp

log "building daytona daemon ${VERSION} for arm64 (downloads Go modules; several minutes)"
(
  cd "${RLP_ROOT}"
  RLP_DAEMON_ARCH=arm64 bash tools/daemon/build-daemon.sh --version "${VERSION}" --force
)

# Patches rename the artifact dir to v0.190.0-rlp<N>. Do not assume the
# upstream tag is the directory name.
BIN="$(find "${RLP_ROOT}/tools/daemon/dist/daemon" -type f -name 'daemon-arm64' | sort | tail -n1)"
[[ -n "${BIN}" && -x "${BIN}" ]] || die "build did not produce daemon-arm64 under tools/daemon/dist"
LABEL="$(basename "$(dirname "${BIN}")")"
log "using ${BIN} (label ${LABEL})"

log "converting to erofs system layer under ${CAS_ROOT}"
(
  cd "${RLP_ROOT}"
  RLP_NFS_ROOT="${CAS_ROOT}" \
  RLP_SYSTEM_DIR="${CAS_ROOT}/system" \
  RLP_DAEMON_ARCH=arm64 \
  bash tools/daemon/convert-system-layer.sh "${BIN}" "${LABEL}"
)

[[ -f "${CAS_ROOT}/system/daemon-arm64.json" ]] || die "daemon-arm64.json was not written"

log "restarting rlp-runner so it picks up the new system layer"
sudo -n systemctl restart rlp-runner
log "done. Next: ./o s"
