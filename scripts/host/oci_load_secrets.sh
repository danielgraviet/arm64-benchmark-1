#!/usr/bin/env bash
# Vera-box: decrypt secrets/oci-vera.enc with a short passphrase.
# Loads GH_TOKEN (and optional keys) into the environment / a sourced file.
#
# Usage:
#   OCI_PASS='four short words' bash scripts/host/oci_load_secrets.sh
#   # then either:
#   bash scripts/host/oci_vera_bootstrap.sh
#   # or source the drop file:
#   set -a; source .env.oci; set +a
#
# Flags:
#   --print-keys   list which vars were loaded (values redacted)
#   --no-export    only write .env.oci (default also exports into current shell
#                  when this script is sourced)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

ENC="${ENC:-${ROOT}/secrets/oci-vera.enc}"
SUM="${SUM:-${ROOT}/secrets/oci-vera.sha256}"
OUT="${OUT:-${ROOT}/.env.oci}"
PRINT_KEYS=0

for arg in "$@"; do
  case "${arg}" in
    --print-keys) PRINT_KEYS=1 ;;
    --no-export) ;; # kept for clarity; writing .env.oci is always done
    *)
      echo "unknown arg: ${arg}" >&2
      exit 2
      ;;
  esac
done

[[ -f "${ENC}" ]] || {
  echo "missing ${ENC}" >&2
  echo "On Mac: OCI_PASS=… GH_TOKEN=… bash scripts/host/oci_pack_secrets.sh && git push" >&2
  exit 1
}

if [[ -z "${OCI_PASS:-}" ]]; then
  printf 'OCI_PASS: '
  stty -echo 2>/dev/null || true
  read -r OCI_PASS
  stty echo 2>/dev/null || true
  printf '\n'
fi
[[ -n "${OCI_PASS}" ]] || { echo "empty OCI_PASS" >&2; exit 1; }

TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT

if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
  -in "${ENC}" -out "${TMP}" -pass "env:OCI_PASS" 2>/dev/null; then
  echo "decrypt failed (wrong OCI_PASS?)" >&2
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
# Keep only KEY=value lines; drop comments/blank.
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "${TMP}" > "${OUT}"
chmod 600 "${OUT}"

# Export into this process (works when sourced OR when parent uses set -a).
set -a
# shellcheck disable=SC1090
source "${OUT}"
set +a

echo "loaded secrets → ${OUT}"
if [[ "${PRINT_KEYS}" -eq 1 ]]; then
  while IFS= read -r line; do
    key="${line%%=*}"
    val="${line#*=}"
    n="${#val}"
    echo "  ${key}=(${n} chars)"
  done < "${OUT}"
fi

# Reminder for the next typed command.
if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "WARN: GH_TOKEN still empty after load" >&2
  exit 1
fi
cat <<EOF
OK: decrypted into ${OUT} (GH_TOKEN length ${#GH_TOKEN} in this process).

IMPORTANT: if you ran this as "bash scripts/host/oci load", your interactive
shell still has GH_TOKEN empty. That is normal. Do NOT echo \$GH_TOKEN to check.
Check the file instead, then boot:

  grep -E '^GH_TOKEN=' .env.oci | wc -c
  bash scripts/host/oci go

Or import into this shell:

  set -a; source .env.oci; set +a
  echo \${#GH_TOKEN}
EOF
