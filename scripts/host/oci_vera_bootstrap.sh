#!/usr/bin/env bash
# Single typed entrypoint for OCI Vera bare-cell bring-up + harness client.
#
# Prereqs (typed once before this script):
#   git clone https://github.com/danielgraviet/arm64-benchmark-1.git
#   cd arm64-benchmark-1
#
# Private RLP clone needs a token (daytona/rlp or danielgraviet/rlp).
# Prefer the encrypted pack (type a short passphrase, not the PAT):
#   OCI_PASS='four words' bash scripts/host/oci go
# Or pack on Mac first:
#   OCI_PASS='…' GH_TOKEN='…' bash scripts/host/oci pack && git push
#
# Guest kernel + initdisk are NOT in git. Place them first, or set paths:
#   RLP_KERNEL=/var/lib/rlp/kernel/Image-arm64 \
#   RLP_INITDISK=/var/lib/rlp/kernel/initdisk-arm64.ext4 \
#   bash scripts/host/oci_vera_bootstrap.sh
#
# Flags / env:
#   SKIP_CELL=1     — harness + eng SDK only (cell already healthy)
#   SKIP_BUILD=1    — reuse existing /usr/local/bin/rlp-* if present
#   RLP_ROOT=~/rlp  — eng source tree (default)
#   RLP_PIN=660e6e3b
#   RLP_GIT_URL     — default https://github.com/daytona/rlp.git
#                     fallback: https://github.com/danielgraviet/rlp.git
#   RLP_NATS_TOKEN / POSTGRES_PASSWORD — generated if unset
#   RLP_API_KEY     — if already minted, written into .env; else mint
#
# See tickets/oci-vera-bare-cell-runbook.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

RLP_ROOT="${RLP_ROOT:-${HOME}/rlp}"
# Short branch on danielgraviet/rlp (== 660e6e3b eng SDK pin). Sha alone was
# missing from incomplete clones / older fork tips on the Nix box.
RLP_PIN="${RLP_PIN:-bench-pin}"
RLP_GIT_URL="${RLP_GIT_URL:-https://github.com/danielgraviet/rlp.git}"
RLP_FALLBACK_GIT_URL="${RLP_FALLBACK_GIT_URL:-https://github.com/daytona/rlp.git}"
SKIP_CELL="${SKIP_CELL:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
FC_VERSION="${FC_VERSION:-1.16.1}"
RUNNER_ID="${RUNNER_ID:-runner-vera-oci-1}"
VM_SUBNET="${VM_SUBNET:-10.101.32.0/20}"
REGION_ID="${REGION_ID:-vera}"
GUEST_DIR="${GUEST_DIR:-/var/lib/rlp/kernel}"

log() { printf '[oci-vera] %s\n' "$*"; }
die() { printf '[oci-vera] ERROR: %s\n' "$*" >&2; exit 1; }

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif sudo -n true 2>/dev/null; then
    sudo "$@"
  else
    die "need root or passwordless sudo for: $*"
  fi
}

# Docker sock is root-only until re-login after usermod -aG docker. Always fall
# back to sudo so Nix sessions do not die on "permission denied ... docker.sock".
run_docker() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    as_root docker "$@"
  fi
}

run_compose() {
  # Usage: run_compose up -d postgres nats
  if docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  else
    as_root docker compose "$@"
  fi
}

detect_public_ip() {
  if [[ -n "${RLP_PUBLIC_IP:-}" ]]; then
    printf '%s' "${RLP_PUBLIC_IP}"
    return
  fi
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -z "${ip}" ]]; then
    ip="127.0.0.1"
  fi
  printf '%s' "${ip}"
}

resolve_guest_paths() {
  if [[ -z "${RLP_KERNEL:-}" ]]; then
    for cand in \
      "${GUEST_DIR}/Image-6.12.34-rlp1-arm64" \
      "${GUEST_DIR}/Image-arm64" \
      "${GUEST_DIR}/Image" \
      "${HOME}/rlp-guest/Image-arm64" \
      "${HOME}/rlp-guest/Image"; do
      if [[ -f "${cand}" ]]; then
        RLP_KERNEL="${cand}"
        break
      fi
    done
  fi
  if [[ -z "${RLP_INITDISK:-}" ]]; then
    for cand in \
      "${GUEST_DIR}/initdisk-arm64.ext4" \
      "${GUEST_DIR}/initdisk-rlp.ext4" \
      "${HOME}/rlp-guest/initdisk-arm64.ext4" \
      /tmp/initdisk-rlp.ext4; do
      if [[ -f "${cand}" ]]; then
        RLP_INITDISK="${cand}"
        break
      fi
    done
  fi
  export RLP_KERNEL RLP_INITDISK
}

apt_packages() {
  log "apt packages"
  export DEBIAN_FRONTEND=noninteractive
  as_root apt-get update -qq
  as_root apt-get install -y -qq \
    git tmux curl ca-certificates build-essential \
    docker.io docker-compose-v2 \
    nftables tcpdump libcap2-bin erofs-utils \
    iproute2 iptables e2fsprogs conntrack \
    pkg-config libssl-dev >/dev/null
  as_root systemctl enable --now docker || true
  if ! groups | grep -qw docker; then
    as_root usermod -aG docker "${USER}" || true
    log "added ${USER} to docker group (re-login may be required for docker without sudo)"
  fi
  as_root usermod -aG kvm "${USER}" 2>/dev/null || true
}

install_uv_and_go_rust_toolchains() {
  if ! command -v uv >/dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
  log "uv $(uv --version)"

  if ! command -v go >/dev/null 2>&1; then
    log "installing go 1.23.x"
    local go_tgz arch
    arch="$(uname -m)"
    case "${arch}" in
      aarch64|arm64) arch=arm64 ;;
      x86_64) arch=amd64 ;;
      *) die "unsupported arch ${arch}" ;;
    esac
    go_tgz="go1.23.6.linux-${arch}.tar.gz"
    curl -fsSL "https://go.dev/dl/${go_tgz}" -o "/tmp/${go_tgz}"
    as_root rm -rf /usr/local/go
    as_root tar -C /usr/local -xzf "/tmp/${go_tgz}"
    export PATH="/usr/local/go/bin:${PATH}"
  fi
  log "go $(go version)"

  if ! command -v cargo >/dev/null 2>&1; then
    log "installing rustup (needed to build rlp-api)"
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    # shellcheck disable=SC1091
    source "${HOME}/.cargo/env"
  fi
  log "cargo $(cargo --version)"
}

clone_rlp() {
  log "RLP tree at ${RLP_ROOT} pin ${RLP_PIN}"
  export GIT_TERMINAL_PROMPT=0
  if [[ -z "${GH_TOKEN:-}" ]]; then
    die "GH_TOKEN unset. On Mac: OCI_PASS=… GH_TOKEN=… bash scripts/host/oci pack && git push. On Vera: source .env.oci then re-run."
  fi

  # Prefer danielgraviet/rlp (fine-grained PAT). Upstream daytona/rlp is fallback.
  local urls=("${RLP_GIT_URL}" "${RLP_FALLBACK_GIT_URL}")
  if [[ "${RLP_PREFER_UPSTREAM:-0}" == "1" ]]; then
    urls=("${RLP_FALLBACK_GIT_URL}" "${RLP_GIT_URL}")
  fi

  local url="" auth_url="" cloned=0
  if [[ ! -d "${RLP_ROOT}/.git" ]]; then
    for url in "${urls[@]}"; do
      auth_url="https://x-access-token:${GH_TOKEN}@${url#https://}"
      log "cloning ${url}"
      if git -c credential.helper= clone "${auth_url}" "${RLP_ROOT}"; then
        cloned=1
        break
      fi
      log "clone ${url} failed"
      rm -rf "${RLP_ROOT}"
    done
    [[ "${cloned}" -eq 1 ]] || die "cannot clone RLP. GH_TOKEN needs Contents:Read on danielgraviet/rlp (or daytona/rlp)"
  else
    url="$(git -C "${RLP_ROOT}" remote get-url origin)"
    case "${url}" in
      *@github.com/*) url="https://github.com/${url#*@github.com/}" ;;
    esac
    log "reusing existing ${RLP_ROOT} (origin ${url})"
  fi

  # Fetch + checkout WHILE the token is on the remote URL. Stripping first
  # caused an interactive username prompt on the Nix terminal after a good clone.
  auth_url="https://x-access-token:${GH_TOKEN}@${url#https://}"
  git -C "${RLP_ROOT}" remote set-url origin "${auth_url}"
  # Explicitly fetch the pin ref (branch or sha). Avoids "pathspec did not match"
  # on incomplete clones from an interrupted Nix session.
  git -c credential.helper= -C "${RLP_ROOT}" fetch --force origin \
    "refs/heads/${RLP_PIN}:refs/remotes/origin/${RLP_PIN}" \
    "${RLP_PIN}" || true
  git -c credential.helper= -C "${RLP_ROOT}" fetch --tags origin || true
  if ! git -c credential.helper= -C "${RLP_ROOT}" checkout --force "${RLP_PIN}"; then
    if ! git -c credential.helper= -C "${RLP_ROOT}" checkout --force "origin/${RLP_PIN}"; then
      git -C "${RLP_ROOT}" remote set-url origin "${url}"
      die "checkout ${RLP_PIN} failed. On Vera type: ./o r"
    fi
  fi
  git -C "${RLP_ROOT}" remote set-url origin "${url}"
  log "RLP HEAD=$(git -C "${RLP_ROOT}" rev-parse --short HEAD) origin=${url}"
}

raise_nofile_and_sysctl() {
  log "nofile + neigh/conntrack sysctls"
  as_root mkdir -p /etc/security/limits.d /etc/systemd/system.conf.d /etc/sysctl.d
  as_root tee /etc/security/limits.d/99-nofile.conf >/dev/null <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
  as_root tee /etc/systemd/system.conf.d/99-nofile.conf >/dev/null <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
  as_root tee /etc/sysctl.d/99-rlp-neigh.conf >/dev/null <<'EOF'
net.ipv4.neigh.default.gc_thresh1 = 8192
net.ipv4.neigh.default.gc_thresh2 = 32768
net.ipv4.neigh.default.gc_thresh3 = 65536
net.ipv6.neigh.default.gc_thresh1 = 8192
net.ipv6.neigh.default.gc_thresh2 = 32768
net.ipv6.neigh.default.gc_thresh3 = 65536
net.netfilter.nf_conntrack_max = 1048576
vm.max_map_count = 1048576
net.ipv4.ip_forward = 1
EOF
  as_root sysctl -p /etc/sysctl.d/99-rlp-neigh.conf || true
  as_root systemctl daemon-reexec || true
}

install_firecracker() {
  if [[ "${SKIP_BUILD}" == "1" ]] && command -v firecracker >/dev/null 2>&1; then
    log "SKIP_BUILD=1; keeping existing firecracker $(firecracker --version 2>&1 | head -n1)"
    return
  fi
  log "Firecracker v${FC_VERSION} aarch64"
  local tgz="/tmp/firecracker-v${FC_VERSION}-aarch64.tgz"
  curl -fsSL \
    "https://github.com/firecracker-microvm/firecracker/releases/download/v${FC_VERSION}/firecracker-v${FC_VERSION}-aarch64.tgz" \
    -o "${tgz}"
  mkdir -p "/tmp/fc-${FC_VERSION}"
  tar xz -C "/tmp/fc-${FC_VERSION}" -f "${tgz}"
  local dir
  dir="$(find "/tmp/fc-${FC_VERSION}" -type d -name "release-v${FC_VERSION}-aarch64" | head -n1)"
  [[ -n "${dir}" ]] || die "firecracker extract failed"
  as_root install -m0755 -o root -g root \
    "${dir}/firecracker-v${FC_VERSION}-aarch64" /usr/local/bin/firecracker
  as_root install -m0755 -o root -g root \
    "${dir}/snapshot-editor-v${FC_VERSION}-aarch64" /usr/local/bin/snapshot-editor
  firecracker --version | head -n1
}

build_and_install_binaries() {
  if [[ "${SKIP_BUILD}" == "1" ]] \
    && command -v rlp-api >/dev/null 2>&1 \
    && command -v rlp-runner >/dev/null 2>&1 \
    && command -v rlp-proxy >/dev/null 2>&1; then
    log "SKIP_BUILD=1; keeping existing rlp-* binaries"
    return
  fi

  # Prefer prebuilt arm64 Go bins if present in the tree.
  local bin_dir="${RLP_ROOT}/deploy/bin-arm64"
  if [[ -x "${bin_dir}/rlp-runner" && -x "${bin_dir}/rlp-fcns" ]]; then
    log "installing prebuilt Go bins from ${bin_dir}"
    as_root install -m0755 -o root -g root "${bin_dir}/rlp-runner" /usr/local/bin/rlp-runner
    as_root install -m0755 -o root -g root "${bin_dir}/rlp-fcns" /usr/local/bin/rlp-fcns
    [[ -x "${bin_dir}/rlp-egressd" ]] && as_root install -m0755 -o root -g root "${bin_dir}/rlp-egressd" /usr/local/bin/rlp-egressd
  else
    log "building Go runner/proxy/fcns (linux/arm64)"
    (
      cd "${RLP_ROOT}/runner"
      GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o /tmp/rlp-runner ./cmd/runner
      GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o /tmp/rlp-fcns ./cmd/rlp-fcns
      if [[ -d cmd/egressd ]]; then
        GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o /tmp/rlp-egressd ./cmd/egressd || true
      fi
    )
    (
      cd "${RLP_ROOT}/proxy"
      GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o /tmp/rlp-proxy ./cmd/proxy
    )
    as_root install -m0755 -o root -g root /tmp/rlp-runner /usr/local/bin/rlp-runner
    as_root install -m0755 -o root -g root /tmp/rlp-fcns /usr/local/bin/rlp-fcns
    as_root install -m0755 -o root -g root /tmp/rlp-proxy /usr/local/bin/rlp-proxy
    [[ -f /tmp/rlp-egressd ]] && as_root install -m0755 -o root -g root /tmp/rlp-egressd /usr/local/bin/rlp-egressd
  fi

  # Always ensure proxy binary exists (may not be in bin-arm64).
  if ! command -v rlp-proxy >/dev/null 2>&1; then
    (
      cd "${RLP_ROOT}/proxy"
      GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o /tmp/rlp-proxy ./cmd/proxy
    )
    as_root install -m0755 -o root -g root /tmp/rlp-proxy /usr/local/bin/rlp-proxy
  fi

  as_root setcap cap_sys_admin+ep /usr/local/bin/rlp-fcns || true

  log "building rlp-api (Rust release) — this can take a long time"
  (
    # shellcheck disable=SC1091
    [[ -f "${HOME}/.cargo/env" ]] && source "${HOME}/.cargo/env"
    cd "${RLP_ROOT}/api"
    cargo build --release
  )
  as_root install -m0755 -o root -g root \
    "${RLP_ROOT}/api/target/release/rlp-api" /usr/local/bin/rlp-api
  as_root mkdir -p /opt/rlp
  as_root ln -sfn /usr/local/bin/rlp-api /opt/rlp/rlp-api
}

setup_dirs_sudoers() {
  as_root mkdir -p /etc/rlp /var/lib/rlp /scratch /opt/rlp/deploy /run/fc /run/netns "${GUEST_DIR}"
  as_root chown -R "${USER}:${USER}" /var/lib/rlp /scratch /opt/rlp || true
  as_root tee /etc/sudoers.d/rlp-runner >/dev/null <<EOF
${USER} ALL=(root) NOPASSWD: /usr/sbin/ip, /usr/bin/ip, /usr/sbin/bridge, /usr/bin/bridge, /usr/sbin/nft, /usr/bin/nft, /usr/sbin/iptables, /sbin/iptables, /usr/sbin/sysctl, /sbin/sysctl, /usr/local/bin/buildctl, /usr/bin/buildctl, /usr/sbin/conntrack, /usr/bin/conntrack
EOF
  as_root chmod 440 /etc/sudoers.d/rlp-runner
  as_root tee /etc/tmpfiles.d/rlp-fc.conf >/dev/null <<EOF
d /run/fc 0755 ${USER} ${USER} -
d /run/netns 0755 ${USER} ${USER} -
EOF
  as_root systemd-tmpfiles --create /etc/tmpfiles.d/rlp-fc.conf 2>/dev/null || true
}

start_postgres_nats() {
  log "postgres + NATS via docker compose"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -hex 16)}"
  RLP_NATS_TOKEN="${RLP_NATS_TOKEN:-$(openssl rand -hex 24)}"
  export POSTGRES_PASSWORD RLP_NATS_TOKEN

  as_root mkdir -p /opt/rlp/deploy
  as_root cp -f "${RLP_ROOT}/deploy/docker-compose.yml" /opt/rlp/deploy/
  as_root cp -f "${RLP_ROOT}/deploy/nats.conf" /opt/rlp/deploy/ 2>/dev/null || true
  as_root cp -f "${RLP_ROOT}/deploy/provision-nats.sh" /opt/rlp/deploy/
  as_root chown -R "${USER}:${USER}" /opt/rlp/deploy

  cat > /opt/rlp/deploy/.env <<EOF
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
RLP_NATS_TOKEN=${RLP_NATS_TOKEN}
EOF
  chmod 600 /opt/rlp/deploy/.env

  # Only postgres + NATS. Full compose also starts MinIO on host :9000, which
  # collides with rlp-proxy toolbox (:9000). Blockmount stays off for Vera parity.
  as_root systemctl enable --now docker || true
  (
    cd /opt/rlp/deploy
    run_compose up -d postgres nats
  )

  log "waiting for postgres"
  local ready=0
  for _ in $(seq 1 90); do
    if run_docker exec rlp-postgres pg_isready -U rlp >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 2
  done
  [[ "${ready}" -eq 1 ]] || die "postgres never became ready (docker/postgres)"

  (
    cd /opt/rlp/deploy
    if ! NATS_TOKEN="${RLP_NATS_TOKEN}" bash ./provision-nats.sh; then
      as_root env NATS_TOKEN="${RLP_NATS_TOKEN}" bash ./provision-nats.sh
    fi
  )
}

write_cell_env() {
  local pub_ip
  pub_ip="$(detect_public_ip)"
  resolve_guest_paths
  if [[ -z "${RLP_KERNEL:-}" || ! -f "${RLP_KERNEL}" || -z "${RLP_INITDISK:-}" || ! -f "${RLP_INITDISK}" ]]; then
    die "guest Image/initdisk missing under ${GUEST_DIR}/. Type: ./o k   then   ./o g"
  fi

  log "writing /etc/rlp/*.env (parity knobs)"
  local pg_pw="${POSTGRES_PASSWORD}"
  local nats="${RLP_NATS_TOKEN}"

  as_root tee /etc/rlp/api.env >/dev/null <<EOF
DATABASE_URL=postgres://rlp:${pg_pw}@127.0.0.1:5439/rlplatform
NATS_URL=nats://127.0.0.1:4222
NATS_TOKEN=${nats}
API_BIND=0.0.0.0:8088
RUST_LOG=rlp_api=info
RLP_BURST_MAX_CPU=1
RLP_BURST_MAX_MEM_MIB=4096
RLP_MIN_CPU=0.025
RLP_MIN_MEM_MIB=64
RLP_MIN_SCRATCH_MIB=1024
EOF
  as_root chmod 600 /etc/rlp/api.env

  # docker-compose may use fixed password from example — sync if container uses rlp_dev_pw
  if grep -q 'rlp_dev_pw' "${RLP_ROOT}/deploy/docker-compose.yml" 2>/dev/null; then
    # Prefer matching whatever compose actually set. Re-read from /opt/rlp/deploy/.env.
    :
  fi

  as_root tee /etc/rlp/proxy.env >/dev/null <<EOF
RLP_PROXY_LISTEN=:9000
RLP_DB_URL=postgres://rlp:${pg_pw}@127.0.0.1:5439/rlplatform
RLP_REGION=${REGION_ID}
RLP_NATS_URL=nats://127.0.0.1:4222
RLP_NATS_TOKEN=${nats}
RLP_API_URL=http://127.0.0.1:8088
EOF
  as_root chmod 600 /etc/rlp/proxy.env

  local scratch_cas="/var/lib/rlp/cas"
  as_root mkdir -p \
    "${scratch_cas}/layers/sha256" \
    "${scratch_cas}/system" \
    "${scratch_cas}/manifests" \
    "${scratch_cas}/templates" \
    /srv/rlp/blockmount
  as_root chown -R "${USER}:${USER}" /var/lib/rlp /srv/rlp || true

  as_root tee /etc/rlp/runner.env >/dev/null <<EOF
RLP_NATS_URL=nats://127.0.0.1:4222
RLP_NATS_TOKEN=${nats}
RLP_RUNNER_ID=${RUNNER_ID}
RLP_RUNNER_REGION=${REGION_ID}
RLP_PUBLIC_IP=${pub_ip}
RLP_SUBNET_CIDR=${VM_SUBNET}
RLP_GUEST_ARCH=arm64
RLP_LOCAL_SCRATCH=/scratch
RLP_INITDISK=${RLP_INITDISK}
RLP_KERNEL=${RLP_KERNEL}
RLP_NFS_ROOT=${scratch_cas}
RLP_CAS_DIR=${scratch_cas}/layers/sha256
RLP_LAYERS_MOUNT=${scratch_cas}/layers
RLP_SYSTEM_DIR=${scratch_cas}/system
RLP_MANIFESTS_DIR=${scratch_cas}/manifests
RLP_TEMPLATE_CAS=1
RLP_TEMPLATE_CAS_DIR=${scratch_cas}/templates
RLP_SNAPSHOTS=1
RLP_NETNS_POOL=2100
RLP_NETNS_NETLINK=1
RLP_KSM=0
RLP_VM_CONCURRENCY=256
RLP_MAX_LIVE_VMS=3000
RLP_BUILD_CONCURRENCY=4
RLP_BLOCKMOUNT_ENABLED=0
RLP_RESERVE_PCT=90
EOF
  as_root chmod 600 /etc/rlp/runner.env
}

install_systemd_units() {
  log "systemd units + rlp.slice"
  if [[ -f "${RLP_ROOT}/deploy/rlp.slice" ]]; then
    as_root cp -f "${RLP_ROOT}/deploy/rlp.slice" /etc/systemd/system/rlp.slice
  fi
  if [[ -f "${RLP_ROOT}/deploy/rlp-cgroup-setup" ]]; then
    as_root install -m0755 -o root -g root \
      "${RLP_ROOT}/deploy/rlp-cgroup-setup" /usr/local/bin/rlp-cgroup-setup
  else
    # Minimal stub so ExecStartPre=+ does not fail hard on fresh cells.
    as_root tee /usr/local/bin/rlp-cgroup-setup >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
mkdir -p /sys/fs/cgroup/rlp.slice/vms
# Best-effort controller + ownership; ignore failures on older cgroup layouts.
echo '+cpu +memory +cpuset' > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
echo '+cpu +memory +cpuset' > /sys/fs/cgroup/rlp.slice/cgroup.subtree_control 2>/dev/null || true
chown -R ${USER}:${USER} /sys/fs/cgroup/rlp.slice 2>/dev/null || true
EOF
    as_root chmod 755 /usr/local/bin/rlp-cgroup-setup
  fi

  as_root cp -f "${RLP_ROOT}/deploy/rlp-api.service" /etc/systemd/system/
  as_root cp -f "${RLP_ROOT}/deploy/rlp-runner.service" /etc/systemd/system/

  # Do NOT copy upstream rlp-proxy.service — it Requires=wg-quick@wg0 and breaks
  # bare OCI cells. Drop-in Clears of Requires= are unreliable across systemd.
  as_root tee /etc/systemd/system/rlp-proxy.service >/dev/null <<EOF
[Unit]
Description=rl-platform toolbox proxy (OCI co-located, no WireGuard)
After=network-online.target rlp-api.service
Wants=network-online.target

[Service]
Type=simple
User=${USER}
EnvironmentFile=/etc/rlp/proxy.env
ExecStart=/usr/local/bin/rlp-proxy
Restart=always
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/etc/rlp

[Install]
WantedBy=multi-user.target
EOF

  # Upstream api/runner hard-code User=ubuntu.
  as_root mkdir -p \
    /etc/systemd/system/rlp-api.service.d \
    /etc/systemd/system/rlp-runner.service.d
  # Remove any stale proxy drop-in from earlier attempts.
  as_root rm -rf /etc/systemd/system/rlp-proxy.service.d

  as_root tee /etc/systemd/system/rlp-api.service.d/oci.conf >/dev/null <<EOF
[Service]
User=${USER}
EOF
  as_root tee /etc/systemd/system/rlp-runner.service.d/oci.conf >/dev/null <<EOF
[Service]
User=${USER}
EOF

  as_root systemctl daemon-reload
  as_root systemctl reset-failed rlp-proxy 2>/dev/null || true
  as_root systemctl enable rlp.slice 2>/dev/null || true
  as_root systemctl enable --now rlp-api
  sleep 2
  as_root systemctl enable --now rlp-proxy
  sleep 1
  as_root systemctl enable --now rlp-runner
}

wait_api_health() {
  log "waiting for API health"
  local i
  for i in $(seq 1 90); do
    if curl -fsS -m 3 http://127.0.0.1:8088/health >/dev/null 2>&1; then
      log "API healthy"
      return 0
    fi
    sleep 2
  done
  die "API health failed. Check: journalctl -u rlp-api -n 80 --no-pager"
}

seed_region_and_mint_key() {
  log "seed regions.id=${REGION_ID} + mint API key"
  # Always go through run_docker (sudo) — same docker.sock permission issue.
  local psql=(run_docker exec -i rlp-postgres psql -U rlp -d rlplatform)

  "${psql[@]}" -v ON_ERROR_STOP=1 <<SQL
-- Partial unique index allows only one is_default=true. Clear first.
UPDATE regions SET is_default=false WHERE is_default=true;
INSERT INTO regions (id, name, status, is_default, toolbox_proxy_url)
VALUES ('${REGION_ID}', 'OCI Vera bare cell', 'active', true, 'http://127.0.0.1:9000/toolbox')
ON CONFLICT (id) DO UPDATE
  SET status='active',
      is_default=true,
      toolbox_proxy_url=EXCLUDED.toolbox_proxy_url,
      updated_at=now();
SQL

  if [[ -n "${RLP_API_KEY:-}" ]]; then
    log "using provided RLP_API_KEY"
    return
  fi

  local project_id org_id
  org_id="$("${psql[@]}" -tAc \
    "SELECT id FROM organizations WHERE name='oci-vera-bootstrap' LIMIT 1;" \
    | tr -d '[:space:]')"
  if [[ -z "${org_id}" ]]; then
    org_id="$("${psql[@]}" -tAc \
      "INSERT INTO organizations (name) VALUES ('oci-vera-bootstrap') RETURNING id;" \
      | tr -d '[:space:]')"
  fi
  project_id="$("${psql[@]}" -tAc \
    "SELECT id FROM projects WHERE org_id='${org_id}' AND name='default' LIMIT 1;" \
    | tr -d '[:space:]')"
  if [[ -z "${project_id}" ]]; then
    project_id="$("${psql[@]}" -tAc \
      "INSERT INTO projects (org_id, name) VALUES ('${org_id}', 'default') RETURNING id;" \
      | tr -d '[:space:]')"
  fi
  [[ -n "${project_id}" ]] || die "could not create/find bootstrap project"

  # mint-key prints plaintext once
  local minted
  minted="$(rlp-api mint-key oci-vera-cli --project "${project_id}" 2>&1 || true)"
  RLP_API_KEY="$(printf '%s\n' "${minted}" | grep -Eo 'dtn_[A-Za-z0-9_-]+|rlp_[A-Za-z0-9_-]+|[A-Za-z0-9_-]{20,}' | head -n1 || true)"
  if [[ -z "${RLP_API_KEY}" ]]; then
    log "mint-key output:"
    printf '%s\n' "${minted}"
    die "could not parse API key from mint-key; set RLP_API_KEY= and re-run"
  fi
  log "minted API key (stored in .env only)"
}

write_client_env() {
  log "writing harness .env"
  local key="${RLP_API_KEY:?RLP_API_KEY required}"
  cat > "${ROOT}/.env" <<EOF
# Generated by scripts/host/oci_vera_bootstrap.sh — never commit.

RLP_API_URL=http://127.0.0.1:8088
RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox
RLP_API_KEY=${key}
RLP_HTTP_MAX_CONNECTIONS=4096

VERA_RLP_API_URL=http://127.0.0.1:8088
VERA_RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox
VERA_RLP_TARGET=vera
VERA_RLP_API_KEY=${key}

REDSWITCHES_RLP_API_URL=http://127.0.0.1:8088
REDSWITCHES_RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox
EOF
  chmod 600 "${ROOT}/.env"
}

harness_uv_and_sdk() {
  log "uv sync + eng rlp-sdk @ ${RLP_PIN}"
  uv python install 3.13
  uv sync
  RLP_ROOT="${RLP_ROOT}" RLP_PIN="${RLP_PIN}" bash "${ROOT}/scripts/host/install_eng_rlp_sdk.sh"
}

print_next() {
  cat <<EOF

[oci-vera] bootstrap finished.

Next (type these):
  bash scripts/host/check_vera_parity.sh
  UV_NO_SYNC=1 uv run python scripts/vera_rlp_smoke.py
  # optional socket pin after rlp.slice exists:
  bash tickets/vera-pin-single-socket.sh
  tmux new-session -d -s vera-c1k bash scripts/host/run_create_ready.sh 1000
  # then 2k + dense — see tickets/oci-vera-bare-cell-runbook.md

Guest artifacts used:
  RLP_KERNEL=${RLP_KERNEL:-unset}
  RLP_INITDISK=${RLP_INITDISK:-unset}
EOF
}

load_packed_secrets() {
  # Prefer already-decrypted drop file, else decrypt enc pack with OCI_PASS.
  if [[ -f "${ROOT}/.env.oci" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${ROOT}/.env.oci"
    set +a
    log "sourced .env.oci"
  fi
  if [[ -n "${GH_TOKEN:-}" ]]; then
    return 0
  fi
  if [[ -f "${ROOT}/secrets/oci-vera.enc" ]]; then
    log "decrypting secrets/oci-vera.enc"
    # shellcheck disable=SC1091
    source "${ROOT}/scripts/host/oci_load_secrets.sh"
  fi
}

# --- main ---
log "ROOT=${ROOT} arch=$(uname -m) user=$(whoami)"
[[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]] \
  || die "expected aarch64 host (got $(uname -m))"

load_packed_secrets

apt_packages
install_uv_and_go_rust_toolchains
raise_nofile_and_sysctl
clone_rlp

if [[ "${SKIP_CELL}" != "1" ]]; then
  setup_dirs_sudoers
  install_firecracker
  build_and_install_binaries
  start_postgres_nats
  write_cell_env
  install_systemd_units
  wait_api_health
  seed_region_and_mint_key
else
  log "SKIP_CELL=1 — not installing cell stack"
  resolve_guest_paths || true
  if [[ -z "${RLP_API_KEY:-}" && -f "${ROOT}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${ROOT}/.env"
    set +a
  fi
  [[ -n "${RLP_API_KEY:-}${VERA_RLP_API_KEY:-}" ]] || die "SKIP_CELL=1 requires RLP_API_KEY or existing .env"
  RLP_API_KEY="${RLP_API_KEY:-${VERA_RLP_API_KEY}}"
fi

write_client_env
harness_uv_and_sdk
print_next
