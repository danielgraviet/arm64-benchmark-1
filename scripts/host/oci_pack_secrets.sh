#!/usr/bin/env bash
# Mac-side: pack OCI secrets into an encrypted blob you can commit/push.
# On the Vera box you only type a short passphrase (no long PAT paste).
#
# Usage (on Mac, where paste works):
#   export GH_TOKEN='ghp_…'          # required: private daytona/rlp clone
#   export RLP_API_KEY='…'           # optional: skip if bootstrap will mint
#   export DOCKERHUB_TOKEN='…'       # optional
#   OCI_PASS='four short words' bash scripts/host/oci_pack_secrets.sh
#
# Writes (safe to commit ciphertext):
#   secrets/oci-vera.enc
#   secrets/oci-vera.sha256   # sha256 of plaintext (integrity after decrypt)
#
# Never commits plaintext. secrets/*.env and secrets/*.plain are gitignored.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

OUT_DIR="${OUT_DIR:-${ROOT}/secrets}"
ENC="${OUT_DIR}/oci-vera.enc"
SUM="${OUT_DIR}/oci-vera.sha256"
PLAIN="${OUT_DIR}/oci-vera.plain"

if [[ -z "${OCI_PASS:-}" ]]; then
  printf 'OCI_PASS (short passphrase you will type on the box): '
  # macOS/Linux without echoing
  stty -echo 2>/dev/null || true
  read -r OCI_PASS
  stty echo 2>/dev/null || true
  printf '\n'
fi
[[ -n "${OCI_PASS}" ]] || { echo "empty OCI_PASS" >&2; exit 1; }

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "GH_TOKEN is required (private RLP clone on OCI)." >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"
umask 077
{
  echo "# generated $(date -u +%Y-%m-%dT%H:%M:%SZ) — do not commit this plaintext"
  echo "GH_TOKEN=${GH_TOKEN}"
  [[ -n "${RLP_API_KEY:-}" ]] && echo "RLP_API_KEY=${RLP_API_KEY}"
  [[ -n "${VERA_RLP_API_KEY:-}" ]] && echo "VERA_RLP_API_KEY=${VERA_RLP_API_KEY}"
  [[ -n "${DOCKERHUB_TOKEN:-}" ]] && echo "DOCKERHUB_TOKEN=${DOCKERHUB_TOKEN}"
  [[ -n "${DOCKERHUB_USER:-}" ]] && echo "DOCKERHUB_USER=${DOCKERHUB_USER}"
  [[ -n "${RLP_GIT_URL:-}" ]] && echo "RLP_GIT_URL=${RLP_GIT_URL}"
} > "${PLAIN}"

# Integrity tag of plaintext (not a password hash — detects typos / bit flips).
shasum -a 256 "${PLAIN}" | awk '{print $1}' > "${SUM}"

# AES-256-CBC + PBKDF2. Passphrase via stdin env for openssl.
openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
  -in "${PLAIN}" -out "${ENC}" -pass "env:OCI_PASS"

# Drop plaintext immediately.
rm -f "${PLAIN}"
chmod 644 "${ENC}" "${SUM}"

echo "wrote ${ENC}"
echo "wrote ${SUM}"
echo
echo "Next on Mac:"
echo "  git add secrets/oci-vera.enc secrets/oci-vera.sha256"
echo "  git commit -m 'oci: encrypted secret pack' && git push"
echo
echo "On Vera (type passphrase only):"
echo "  OCI_PASS='…' bash scripts/host/oci_load_secrets.sh"
echo "  bash scripts/host/oci_vera_bootstrap.sh"
