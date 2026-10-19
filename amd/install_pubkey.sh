#!/usr/bin/env bash
# Mac: install this machine's SSH pubkey on the AMD box (password once via .env.amd).
set -euo pipefail

AMD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${AMD_DIR}/.env.amd"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ENV_FILE}"
  set +a
fi

PUB="${AMD_SSH_PUBKEY_FILE:-${HOME}/.ssh/id_ed25519.pub}"
if [[ ! -f "${PUB}" ]]; then
  PUB="${HOME}/.ssh/id_rsa.pub"
fi
[[ -f "${PUB}" ]] || { echo "no pubkey at ~/.ssh/id_ed25519.pub or id_rsa.pub" >&2; exit 1; }

KEY="$(tr -d '\n' <"${PUB}")"
bash "${AMD_DIR}/ssh" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF '${KEY}' ~/.ssh/authorized_keys || echo '${KEY}' >> ~/.ssh/authorized_keys && echo pubkey_ok"
echo "next: ./amd/ssh should work without password"
