#!/usr/bin/env bash
# Re-mint a cell API key with --permissions all and rewrite harness .env.
# The first bootstrap omitted --permissions, so .env got a UUID and smoke 401s.
#
# Typed: ./o m
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

log() { printf '[oci-mint] %s\n' "$*"; }
die() { printf '[oci-mint] ERROR: %s\n' "$*" >&2; exit 1; }

command -v rlp-api >/dev/null || die "rlp-api not on PATH"
sudo -n true 2>/dev/null || die "need passwordless sudo"

DATABASE_URL="$(sudo -n grep -E '^DATABASE_URL=' /etc/rlp/api.env | tail -n1 | cut -d= -f2-)"
[[ -n "${DATABASE_URL}" ]] || die "DATABASE_URL missing in /etc/rlp/api.env"
export DATABASE_URL

run_docker() {
  if docker info >/dev/null 2>&1; then docker "$@"
  else sudo -n docker "$@"
  fi
}

project_id="$(
  run_docker exec -i rlp-postgres psql -U rlp -d rlplatform -qAt <<'SQL'
SELECT p.id
FROM projects p
JOIN organizations o ON o.id = p.org_id
WHERE o.name = 'oci-vera-bootstrap' AND p.name = 'default'
LIMIT 1;
SQL
)"
project_id="$(printf '%s' "${project_id}" | awk 'NF{print; exit}')"
[[ "${project_id}" =~ ^[0-9a-fA-F-]{36}$ ]] || die "no bootstrap project (got '${project_id}')"

log "minting key for project ${project_id}"
minted="$(rlp-api mint-key oci-vera-cli --project "${project_id}" --permissions all 2>&1)" || {
  printf '%s\n' "${minted}" >&2
  die "mint-key failed"
}
key="$(printf '%s\n' "${minted}" | grep -Eo 'rlp_[0-9a-f]{32}' | head -n1 || true)"
[[ -n "${key}" ]] || {
  printf '%s\n' "${minted}" >&2
  die "no rlp_ token in mint output"
}

umask 077
if [[ -f "${ROOT}/.env" ]]; then
  grep -v -E '^(RLP_API_KEY|VERA_RLP_API_KEY)=' "${ROOT}/.env" > "${ROOT}/.env.tmp" || true
  mv "${ROOT}/.env.tmp" "${ROOT}/.env"
else
  : > "${ROOT}/.env"
fi
cat >> "${ROOT}/.env" <<EOF
RLP_API_KEY=${key}
VERA_RLP_API_KEY=${key}
EOF
chmod 600 "${ROOT}/.env"
log "wrote .env (key length ${#key}). Next: ./o s"
