#!/bin/bash
# Remove host network state left by the discarded main-build runner, then rebuild it from the f0611fa13 runner.
set -u
K=$(sudo cat /etc/rlp/bench-api-key)
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1"; }
# 1) delete leftover sandboxes through the API, then stop the runner
for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" http://127.0.0.1:8088/vms/$id; done
sleep 5; sudo systemctl stop rlp-runner; sleep 2; sudo pkill -9 -x firecracker 2>/dev/null; true
# 2) every rlp_* nft table (f0611fa13 re-creates its own on start) + every rlp netns/veth + VM routes
for t in $(sudo nft list tables | awk '$3 ~ /^rlp_/ {print $2" "$3}' | tr ' ' ':'); do sudo nft delete table ${t%%:*} ${t##*:} && echo "deleted nft table ${t/:/ }"; done
for ns in $(sudo ip netns list | awk '{print $1}' | grep '^rlp'); do sudo ip netns del $ns; done
for l in $(ip -o link | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -E '^rlp'); do sudo ip link del $l 2>/dev/null; done
ip route | awk '/dev rlpvh/{print $1}' | while read r; do sudo ip route del $r 2>/dev/null; done
sudo rm -rf /run/fc/* /mnt/data/rlp/scratch/* /mnt/data/rlp/templates/* 2>/dev/null
sudo rm -f /var/lib/rlp/ipam*.json 2>/dev/null
echo "after reset: nft rlp tables=$(sudo nft list tables | grep -c rlp_) netns=$(sudo ip netns list | wc -l) rlp links=$(ip -o link | grep -c ': rlp')"
PG "update vms set status='deleted' where status not in ('deleted','failed','lost')" >/dev/null
# 3) restart runner and wait for the pool
sudo systemctl start rlp-runner
for i in $(seq 1 120); do n=$(sudo ip netns list | wc -l); [ $n -ge 2000 ] && break; sleep 5; done
echo "runner=$(systemctl is-active rlp-runner) netns=$(sudo ip netns list | wc -l) tables: $(sudo nft list tables | awk '$3 ~ /^rlp_/{print $2" "$3}' | tr '\n' ',')"
