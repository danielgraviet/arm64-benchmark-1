#!/bin/bash
# After booting a different page-size kernel: fresh templates (snapshots minted on the other kernel), runner restart, pool warm.
set -u
R=/mnt/data/rlp
echo "kernel $(uname -r) page=$(getconf PAGESIZE) cmdline: $(cat /proc/cmdline)"
sudo sysctl -q -p /etc/sysctl.d/90-rlp-bench.conf
sudo systemctl stop rlp-runner; sudo rm -rf $R/templates/*; sudo systemctl start rlp-runner
echo "$(date -u +%FT%TZ) $(uname -r): wiped $R/templates (snapshots from the other page size), restarted runner" | sudo tee -a /etc/rlp/HOSTCHANGES >/dev/null
for i in $(seq 1 120); do [ "$(sudo ip netns list | wc -l)" -ge 2100 ] && break; sleep 5; done
echo "services: api=$(systemctl is-active rlp-api) proxy=$(systemctl is-active rlp-proxy) runner=$(systemctl is-active rlp-runner) pg=$(sudo docker inspect -f '{{.State.Status}}' rlp-postgres) nats=$(sudo docker inspect -f '{{.State.Status}}' rlp-nats) netns=$(sudo ip netns list | wc -l)"
bench-startup 10 3 2>&1 | grep -E "^rep"
