#!/bin/bash
# Deploy the fixes build and turn on all four create-path fixes.
set -euo pipefail
B=$HOME/rlp-build; O=$B/out-fixes
say() { echo "[$(date -u +%T)] $*"; }
say "draining before the swap"
bash /tmp/ph-clean.sh >/dev/null 2>&1 || true
sudo systemctl stop rlp-runner rlp-api
sudo cp -n /usr/local/bin/rlp-runner /usr/local/bin/rlp-runner.bak-prefixes 2>/dev/null || true
sudo cp -n /opt/rlp/rlp-api /opt/rlp/rlp-api.bak-prefixes 2>/dev/null || true
sudo install -m 755 $O/rlp-runner /usr/local/bin/rlp-runner
sudo install -m 755 $O/rlp-api /opt/rlp/rlp-api
# ---- knobs ----
sudo sed -i '/^RLP_INITDISK_MODE=/d;/^RLP_CGROUP_POOL=/d;/^RLP_NEIGH_PERMANENT=/d' /etc/rlp/runner.env
sudo tee -a /etc/rlp/runner.env >/dev/null <<'K'
# create-path fixes measured on HQ Vera (bench build; none merged upstream)
RLP_INITDISK_MODE=nofsync
RLP_CGROUP_POOL=2400
RLP_NEIGH_PERMANENT=1
K
sudo sed -i '/^RLP_API_LISTEN_BACKLOG=/d' /etc/rlp/api.env
echo 'RLP_API_LISTEN_BACKLOG=4096' | sudo tee -a /etc/rlp/api.env >/dev/null
echo "$(date -u +%FT%TZ) fixes build deployed: #3260 RLP_INITDISK_MODE=nofsync, #3261 RLP_CGROUP_POOL=2400, #3265 RLP_NEIGH_PERMANENT=1, #3269 RLP_API_LISTEN_BACKLOG=4096. runner sha $(sha256sum $O/rlp-runner | cut -c1-12), api sha $(sha256sum $O/rlp-api | cut -c1-12). Previous binaries kept as *.bak-prefixes. NOTE #3261 names cgroups from a pool, so post-restart adoption cannot match them to VM ids." | sudo tee -a /etc/rlp/HOSTCHANGES >/dev/null
sudo systemctl start rlp-api
for i in $(seq 1 60); do curl -fsS -m2 127.0.0.1:8088/health >/dev/null 2>&1 && break; sleep 2; done
sudo systemctl start rlp-runner
say "api=$(systemctl is-active rlp-api) runner=$(systemctl is-active rlp-runner)"
say "waiting for the netns pool"
for i in $(seq 1 240); do n=$(sudo ip netns list | wc -l); [ "$n" -ge 6100 ] && break; sleep 10; done
say "netns=$(sudo ip netns list | wc -l)"
echo "---- verification ----"
echo "#3269 listen backlog (Send-Q on :8088, want 4096):"; ss -ltn | awk '$4 ~ /:8088$/ {print "   Send-Q="$3}'
echo "#3269 log line:"; sudo journalctl -u rlp-api --since "-10min" --no-pager | grep -i "listen backlog" | tail -1
echo "#3261 cgroup pool dirs:"; echo "   $(sudo ls /sys/fs/cgroup/rlp.slice/vms 2>/dev/null | grep -c '^vm-pool-') pre-created"
echo "#3261 pool warning:"; sudo journalctl -u rlp-runner --since "-10min" --no-pager -o cat | grep -i "cgroup pool enabled" | tail -1
echo "#3265 permanent neigh entries in pool netns (sample 3):"
for ns in $(sudo ip netns list | awk '{print $1}' | head -3); do printf "   %s: %s\n" "$ns" "$(sudo ip netns exec $ns ip neigh show nud permanent 2>/dev/null | head -1)"; done
echo "#3260 mode in the live runner env:"; sudo bash -c 'tr "\0" "\n" < /proc/$(pgrep -nx rlp-runner)/environ | grep -E "RLP_INITDISK_MODE|RLP_CGROUP_POOL|RLP_NEIGH_PERMANENT"' | sed 's/^/   /'
