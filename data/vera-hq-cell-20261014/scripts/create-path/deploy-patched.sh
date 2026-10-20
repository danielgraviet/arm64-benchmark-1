#!/bin/bash
set -u
sudo systemctl stop rlp-runner rlp-api
sudo cp -a /usr/local/bin/rlp-runner /usr/local/bin/rlp-runner.bak-prepatch 2>/dev/null
sudo cp -a /opt/rlp/rlp-api /opt/rlp/rlp-api.bak-prepatch 2>/dev/null
sudo install -m 755 /tmp/rlp-runner-patched /usr/local/bin/rlp-runner
sudo install -m 755 /home/daytona/rlp-build/src/api/target/release/rlp-api /opt/rlp/rlp-api
sudo systemctl start rlp-api; sleep 3; sudo systemctl start rlp-runner
echo "runner $(sha256sum /usr/local/bin/rlp-runner | cut -c1-12) (was $(sha256sum /usr/local/bin/rlp-runner.bak-prepatch | cut -c1-12))"
echo "api    $(sha256sum /opt/rlp/rlp-api | cut -c1-12) (was $(sha256sum /opt/rlp/rlp-api.bak-prepatch | cut -c1-12))"
echo "$(date -u +%FT%TZ) deployed patched runner+api (flags default OFF: RLP_INITDISK_MODE=copy, RLP_NEIGH_PERMANENT unset, RLP_CGROUP_POOL=0, RLP_API_LISTEN_BACKLOG=128). Backups: *.bak-prepatch" | sudo tee -a /etc/rlp/HOSTCHANGES >/dev/null
for i in $(seq 1 120); do curl -fsS -m 2 http://127.0.0.1:8088/health >/dev/null 2>&1 && break; sleep 1; done
for i in $(seq 1 120); do n=$(sudo ip netns list | wc -l); [ "$n" -ge 1995 ] && break; sleep 5; done
echo "api=$(systemctl is-active rlp-api) runner=$(systemctl is-active rlp-runner) pool=$(sudo ip netns list | wc -l) backlog=$(ss -ltn 'sport = :8088' | awk 'NR==2{print $2+$3}')"
sudo journalctl -u rlp-api --since -3min --no-pager -o cat | grep -i "accept backlog" | tail -1
