#!/usr/bin/env bash
# Host + runner tuning for create-ready 1k/2k on the epyc9575 cell.
# See epyc9575-create-ready-debug.md ("ARP neighbor table overflow").
#
# Run as root on the DUT (sudo costs ~70 s per call on these hosts):
#   bash scripts/host/tune_epyc9575_create.sh            # sysctls only
#   CONC=256 bash scripts/host/tune_epyc9575_create.sh   # + RLP_VM_CONCURRENCY, restart runner
set -euo pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "run as root" >&2; exit 1; }

# The kernel neighbor table is global across netns. Default gc_thresh3=1024
# overflows at ~1k live VMs ("neighbour: arp_cache: neighbor table overflow!"),
# the runner cannot reach resumed guests, and toolbox_wait stretches to minutes.
cat > /etc/sysctl.d/99-rlp-neigh.conf <<'EOF'
# RLP: neighbor table is global across netns; default 1024 overflows at ~1k VMs (toolbox_wait stalls).
net.ipv4.neigh.default.gc_thresh1 = 8192
net.ipv4.neigh.default.gc_thresh2 = 32768
net.ipv4.neigh.default.gc_thresh3 = 65536
net.ipv6.neigh.default.gc_thresh1 = 8192
net.ipv6.neigh.default.gc_thresh2 = 32768
net.ipv6.neigh.default.gc_thresh3 = 65536
EOF
sysctl -p /etc/sysctl.d/99-rlp-neigh.conf

# Burst cap defaults to 16.0 in the API. The create-ready client sends no cpu_max,
# so every 0.025-cpu sandbox booted as a 16-vCPU guest and guest CPU pinned the
# host (~90% gu, run queue 3000). Sep 8's ~32 s cell had RLP_BURST_MAX_CPU=1.
if ! grep -qx 'RLP_BURST_MAX_CPU=1' /etc/rlp/api.env; then
  cp -a /etc/rlp/api.env "/etc/rlp/api.env.bak-$(date -u +%Y%m%d_%H%M%S)"
  sed -i '/^RLP_BURST_MAX_CPU=/d' /etc/rlp/api.env
  echo 'RLP_BURST_MAX_CPU=1' >> /etc/rlp/api.env
  systemctl restart rlp-api
  until curl -fsS http://127.0.0.1:8088/health >/dev/null 2>&1; do sleep 2; done
fi

if [[ -n "${CONC:-}" ]]; then
  cp -a /etc/rlp/runner.env "/etc/rlp/runner.env.bak-$(date -u +%Y%m%d_%H%M%S)"
  sed -i '/^RLP_VM_CONCURRENCY=/d' /etc/rlp/runner.env
  echo "RLP_VM_CONCURRENCY=${CONC}" >> /etc/rlp/runner.env
  systemctl restart rlp-runner
  until curl -fsS http://127.0.0.1:8088/health >/dev/null 2>&1; do sleep 5; done
  tr '\0' '\n' < "/proc/$(pidof rlp-runner)/environ" | grep '^RLP_VM_CONCURRENCY='
fi
