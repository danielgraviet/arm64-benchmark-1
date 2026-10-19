#!/usr/bin/env bash
# One-time DUT setup: Python 3.13, uv sync, nofile. No Codex.
# Run from the clone as root or as ubuntu with passwordless sudo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
NOFILE="${NOFILE:-1048576}"

log() { printf '%s\n' "$*"; }

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif sudo -n true 2>/dev/null; then
    sudo "$@"
  else
    log "need root or passwordless sudo for: $*"
    exit 1
  fi
}

export DEBIAN_FRONTEND=noninteractive
as_root apt-get update -qq
as_root apt-get install -y -qq git tmux curl ca-certificates python3-venv build-essential >/dev/null

if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="${HOME}/.local/bin:${PATH}"
fi
log "uv $(uv --version)"

uv python install 3.13
uv sync
py="$(uv run python -c 'import sys; print(sys.version.split()[0])')"
log "uv run python ${py}"
case "${py}" in
  3.13.*) ;;
  *)
    log "expected CPython 3.13, got ${py}"
    exit 1
    ;;
esac

as_root mkdir -p /etc/security/limits.d /etc/systemd/system.conf.d
as_root tee /etc/security/limits.d/99-nofile.conf >/dev/null <<EOF
* soft nofile ${NOFILE}
* hard nofile ${NOFILE}
root soft nofile ${NOFILE}
root hard nofile ${NOFILE}
EOF
as_root tee /etc/systemd/system.conf.d/99-nofile.conf >/dev/null <<EOF
[Manager]
DefaultLimitNOFILE=${NOFILE}
EOF
as_root systemctl daemon-reexec || true
log "wrote PAM + systemd DefaultLimitNOFILE=${NOFILE}"

if [[ ! -f "${ROOT}/.env" ]]; then
  cp "${ROOT}/.env.example" "${ROOT}/.env"
  chmod 600 "${ROOT}/.env"
  log "wrote .env from .env.example. Fill RLP_API_KEY by hand."
fi

grep -q '.local/bin' "${HOME}/.profile" 2>/dev/null \
  || echo 'export PATH="$HOME/.local/bin:$PATH"' >>"${HOME}/.profile"

log "bootstrap done. Next: SETUP.md step 3 (API key) then smoke."
