#!/usr/bin/env bash
# One-time RedSwitches DUT setup: Python 3.13, uv sync, nofile, Codex, gh.
# Run as root from a clone of this repo. Does not write .env secrets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
NOFILE="${NOFILE:-1048576}"

log() { printf '%s\n' "$*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log "bootstrap must run as root on the DUT"
    exit 1
  fi
}

apt_base() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq git tmux curl ca-certificates python3-venv build-essential >/dev/null
}

install_uv() {
  if ! command -v uv >/dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
  log "uv $(uv --version)"
}

install_python_and_sync() {
  uv python install 3.13
  uv sync
  local py
  py="$(uv run python -c 'import sys; print(sys.version.split()[0])')"
  log "uv run python ${py}"
  case "${py}" in
    3.13.*) ;;
    *)
      log "expected CPython 3.13, got ${py}"
      exit 1
      ;;
  esac
}

raise_nofile() {
  mkdir -p /etc/security/limits.d
  cat >/etc/security/limits.d/99-nofile.conf <<EOF
* soft nofile ${NOFILE}
* hard nofile ${NOFILE}
root soft nofile ${NOFILE}
root hard nofile ${NOFILE}
EOF
  mkdir -p /etc/systemd/system.conf.d
  cat >/etc/systemd/system.conf.d/99-nofile.conf <<EOF
[Manager]
DefaultLimitNOFILE=${NOFILE}
EOF
  systemctl daemon-reexec || true
  log "wrote PAM + systemd DefaultLimitNOFILE=${NOFILE} (new logins pick this up)"
}

install_gh() {
  if command -v gh >/dev/null 2>&1; then
    log "gh $(gh --version | head -n1)"
    return
  fi
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg status=none
  chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  mkdir -p /etc/apt/sources.list.d
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    >/etc/apt/sources.list.d/github-cli.list
  apt-get update -qq
  apt-get install -y -qq gh >/dev/null
  log "gh $(gh --version | head -n1)"
}

install_codex() {
  if ! command -v codex >/dev/null 2>&1; then
    curl -fsSL https://chatgpt.com/codex/install.sh | sh
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
  if command -v codex >/dev/null 2>&1; then
    log "codex $(codex --version 2>/dev/null || echo installed)"
  else
    log "codex binary not on PATH yet. Open a new shell or source ~/.local/bin"
  fi
}

git_identity() {
  git config --global init.defaultBranch main
  if [[ -z "$(git config --global user.name || true)" ]]; then
    git config --global user.name "Daniel Thi Graviet"
  fi
  if [[ -z "$(git config --global user.email || true)" ]]; then
    git config --global user.email "danielthigraviet@gmail.com"
  fi
  log "git user=$(git config --global user.name) <$(git config --global user.email)>"
}

seed_env_example() {
  if [[ ! -f "${ROOT}/.env" ]]; then
    cp "${ROOT}/.env.example" "${ROOT}/.env"
    chmod 600 "${ROOT}/.env"
    log "wrote ${ROOT}/.env from .env.example. Fill RLP_API_KEY by hand."
  else
    log ".env already present (not overwritten)"
  fi
}

install_pubkey() {
  if [[ -z "${SSH_PUBKEY:-}" ]]; then
    log "SSH_PUBKEY unset. Skip authorized_keys."
    return
  fi
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  touch /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  if grep -qxF "${SSH_PUBKEY}" /root/.ssh/authorized_keys; then
    log "SSH_PUBKEY already in authorized_keys"
  else
    printf '%s\n' "${SSH_PUBKEY}" >>/root/.ssh/authorized_keys
    log "appended SSH_PUBKEY to /root/.ssh/authorized_keys"
  fi
}

print_next() {
  cat <<'EOF'

bootstrap done. Still manual on this box:
  1. Put the RLP API key in .env (never commit it).
  2. gh auth login  (fine-grained PAT, repo contents:write)
  3. Headless Codex:  codex login --device-auth
     or: printenv OPENAI_API_KEY | codex login --with-api-key
  4. curl -fsS http://127.0.0.1:8088/health
  5. uv run pytest
  6. tmux new-session -s codex
  7. On the Mac: Host rs-new in ~/.ssh/config with your ed25519 key.

Do not reboot because MOTD said restart required.
Do not use UV_NO_SYNC on this host. uv sync already selected Python 3.13.
EOF
}

need_root
apt_base
install_uv
install_python_and_sync
raise_nofile
install_gh
install_codex
git_identity
seed_env_example
install_pubkey
print_next
