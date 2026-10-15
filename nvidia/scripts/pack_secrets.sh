#!/usr/bin/env bash
# Mac-side: pack NVIDIA Zen5 secrets into an encrypted blob you can commit/push.
# On the 9755 box she only types a short passphrase (no long PAT paste).
#
# Usage (on Mac, where paste works):
#   export GH_TOKEN='github_pat_…'   # read rlp-bench-pin + write arm64-benchmark-1
#   # optional:
#   # export RLP_API_KEY='…'        # skip if ./o start will mint
#   # export DOCKERHUB_TOKEN='…'
#   NVIDIA_PASS='four short words' bash nvidia/scripts/pack_secrets.sh
#
# Writes (safe to commit ciphertext):
#   secrets/nvidia-zen5.enc
#   secrets/nvidia-zen5.sha256
#
# Never commits plaintext. secrets/*.plain and .env.nvidia are gitignored.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}"

OUT_DIR="${OUT_DIR:-${ROOT}/secrets}"
ENC="${OUT_DIR}/nvidia-zen5.enc"
SUM="${OUT_DIR}/nvidia-zen5.sha256"
PLAIN="${OUT_DIR}/nvidia-zen5.plain"

# Accept OCI_PASS as alias so muscle memory from Vera pack works.
PASS="${NVIDIA_PASS:-${OCI_PASS:-}}"
if [[ -z "${PASS}" ]]; then
  printf 'NVIDIA_PASS (short passphrase you will tell Ananya): '
  stty -echo 2>/dev/null || true
  read -r PASS
  stty echo 2>/dev/null || true
  printf '\n'
fi
[[ -n "${PASS}" ]] || { echo "empty NVIDIA_PASS" >&2; exit 1; }

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "GH_TOKEN is required (clone danielgraviet/rlp-bench-pin + push JSONL)." >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"
umask 077
{
  echo "# generated $(date -u +%Y-%m-%dT%H:%M:%SZ) — do not commit this plaintext"
  echo "GH_TOKEN=${GH_TOKEN}"
  [[ -n "${RLP_API_KEY:-}" ]] && echo "RLP_API_KEY=${RLP_API_KEY}"
  [[ -n "${DOCKERHUB_TOKEN:-}" ]] && echo "DOCKERHUB_TOKEN=${DOCKERHUB_TOKEN}"
  [[ -n "${DOCKERHUB_USER:-}" ]] && echo "DOCKERHUB_USER=${DOCKERHUB_USER}"
  [[ -n "${RLP_GIT_URL:-}" ]] && echo "RLP_GIT_URL=${RLP_GIT_URL}"
} > "${PLAIN}"

shasum -a 256 "${PLAIN}" | awk '{print $1}' > "${SUM}"

NVIDIA_PASS="${PASS}" openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
  -in "${PLAIN}" -out "${ENC}" -pass "env:NVIDIA_PASS"

rm -f "${PLAIN}"
chmod 644 "${ENC}" "${SUM}"

echo "wrote ${ENC}"
echo "wrote ${SUM}"
echo
echo "Next on Mac:"
echo "  git add secrets/nvidia-zen5.enc secrets/nvidia-zen5.sha256"
echo "  git commit -m 'nvidia: encrypted secret pack' && git push"
echo
echo "Tell Ananya the passphrase only. On the 9755:"
echo "  cd arm64-benchmark-1/nvidia"
echo "  NVIDIA_PASS='…' ./o load"
echo "  ./o start"
