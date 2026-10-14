#!/usr/bin/env bash
# 9755 box: decrypt secrets/nvidia-zen5.enc with a short passphrase.
# Writes .env.nvidia (gitignored) and exports into this process when sourced.
#
# Usage:
#   NVIDIA_PASS='four short words' bash nvidia/scripts/load_secrets.sh
#   # or:  cd nvidia && NVIDIA_PASS='…' ./o load
#
# Then:
#   ./o start          # auto-sources .env.nvidia if GH_TOKEN unset
#   # or: set -a; source ../.env.nvidia; set +a
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}"

ENC="${ENC:-${ROOT}/secrets/nvidia-zen5.enc}"
SUM="${SUM:-${ROOT}/secrets/nvidia-zen5.sha256}"
OUT="${OUT:-${ROOT}/.env.nvidia}"
PRINT_KEYS=0

for arg in "$@"; do
  case "${arg}" in
    --print-keys) PRINT_KEYS=1 ;;
    --no-export) ;;
    *)
      echo "unknown arg: ${arg}" >&2
      exit 2
      ;;
  esac
done

[[ -f "${ENC}" ]] || {
  echo "missing ${ENC}" >&2
  echo "On Mac: NVIDIA_PASS=… GH_TOKEN=… bash nvidia/scripts/pack_secrets.sh && git push" >&2
  exit 1
}

PASS="${NVIDIA_PASS:-${OCI_PASS:-}}"
if [[ -z "${PASS}" ]]; then
  printf 'NVIDIA_PASS: '
  stty -echo 2>/dev/null || true
  read -r PASS
  stty echo 2>/dev/null || true
  printf '\n'
fi
[[ -n "${PASS}" ]] || { echo "empty NVIDIA_PASS" >&2; exit 1; }

TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT

export NVIDIA_PASS="${PASS}"
if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
  -in "${ENC}" -out "${TMP}" -pass "env:NVIDIA_PASS" 2>/dev/null; then
  echo "decrypt failed (wrong NVIDIA_PASS?)" >&2
  exit 1
fi

if [[ -f "${SUM}" ]]; then
  got="$(shasum -a 256 "${TMP}" | awk '{print $1}')"
  want="$(tr -d '[:space:]' < "${SUM}")"
  if [[ "${got}" != "${want}" ]]; then
    echo "sha256 mismatch after decrypt (corrupt pack or wrong passphrase)" >&2
    echo "  want=${want}" >&2
    echo "  got=${got}" >&2
    exit 1
  fi
fi

umask 077
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "${TMP}" > "${OUT}"
chmod 600 "${OUT}"

set -a
# shellcheck disable=SC1090
source "${OUT}"
set +a

echo "loaded secrets → ${OUT}"
if [[ "${PRINT_KEYS}" -eq 1 ]]; then
  while IFS= read -r line; do
    key="${line%%=*}"
    val="${line#*=}"
    echo "  ${key}=(${#val} chars)"
  done < "${OUT}"
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "WARN: GH_TOKEN still empty after load" >&2
  exit 1
fi

cat <<EOF
OK: decrypted into ${OUT} (GH_TOKEN length ${#GH_TOKEN} in this process).

If you ran "./o load" as a subprocess, your interactive shell may still lack
GH_TOKEN. That is fine — ./o start reads .env.nvidia automatically:

  ./o start

Or import into this shell:

  set -a; source ${OUT}; set +a
  echo \${#GH_TOKEN}
EOF
