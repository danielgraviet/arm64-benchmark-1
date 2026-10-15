#!/bin/bash
# Raise the configured caps so the concurrency ladder measures the machine, not the config.
#   netns pool 2100 -> 6200, max live VMs 3000 -> 8000, subnet /20 (4094 usable) -> /18 (16382).
# The CIDR change needs the old netns and nft state gone, so the runner is stopped first.
set -euo pipefail
say() { echo "[$(date -u +%T)] $*"; }

say "stopping runner"
sudo systemctl stop rlp-runner; sleep 3
sudo pkill -x firecracker 2>/dev/null || true; sleep 2

say "clearing netns ($(sudo ip netns list | wc -l)) and rlp_* nft tables ($(sudo nft list tables 2>/dev/null | grep -c rlp_ || true))"
for ns in $(sudo ip netns list | awk '{print $1}'); do sudo ip netns del "$ns" 2>/dev/null || true; done
sudo nft list tables 2>/dev/null | grep ' rlp_' | while read -r _ fam name; do sudo nft delete table "$fam" "$name" 2>/dev/null || true; done
sudo rm -rf /run/fc/* 2>/dev/null || true

say "rewriting caps in /etc/rlp/runner.env"
sudo sed -i -e 's|^RLP_NETNS_POOL=.*|RLP_NETNS_POOL=6200|' \
            -e 's|^RLP_MAX_LIVE_VMS=.*|RLP_MAX_LIVE_VMS=8000|' \
            -e 's|^RLP_SUBNET_CIDR=.*|RLP_SUBNET_CIDR=10.102.0.0/18|' /etc/rlp/runner.env
sudo grep -E '^RLP_(NETNS_POOL|MAX_LIVE_VMS|SUBNET_CIDR|VM_CONCURRENCY)=' /etc/rlp/runner.env
echo "$(date -u +%FT%TZ) capacity ladder: NETNS_POOL 2100->6200, MAX_LIVE_VMS 3000->8000, SUBNET_CIDR /20->/18 (a /20 caps the host at 4094 sandboxes)" | sudo tee -a /etc/rlp/HOSTCHANGES >/dev/null

say "starting runner; waiting for the netns pool to refill (burns CPU until it is done)"
sudo systemctl start rlp-runner
for i in $(seq 1 180); do
  n=$(sudo ip netns list | wc -l)
  [ "$n" -ge 6100 ] && break
  [ $((i % 15)) = 0 ] && say "  netns=$n"
  sleep 5
done
say "netns=$(sudo ip netns list | wc -l) runner=$(systemctl is-active rlp-runner)"
sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc \
  "select id||' '||status||' live='||coalesce((capacity->>'live_vms'),'?')||' max='||coalesce((capacity->>'max_live_vms'),'?') from runners" 2>/dev/null || true
say "waiting for the pool-refill CPU to settle"
for i in $(seq 1 60); do l=$(cut -d' ' -f1 /proc/loadavg); [ "${l%%.*}" -lt 5 ] && break; sleep 10; done
say "load=$(cut -d' ' -f1-3 /proc/loadavg)"
