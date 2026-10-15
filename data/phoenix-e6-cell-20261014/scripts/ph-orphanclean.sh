#!/bin/bash
# Recover from the lost-sweep: the rows are terminal `lost`, so the delete API cannot reach the
# guests. Kill the orphans directly, clear the runtime dirs, restart the runner.
set -u
echo "$(date -u +%T) orphans fc=$(pgrep -c firecracker) lost_rows=$(sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "select count(*) from vms where status='lost'" 2>/dev/null)"
sudo systemctl stop rlp-runner
sudo pkill -x firecracker; sleep 20
for i in $(seq 1 30); do [ "$(pgrep -c firecracker)" = 0 ] && break; sudo pkill -9 -x firecracker; sleep 5; done
sudo rm -rf /run/fc/* 2>/dev/null
sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc \
  "update vms set status='deleted' where status not in ('deleted')" >/dev/null 2>&1
sudo systemctl start rlp-runner
for i in $(seq 1 240); do n=$(sudo ip netns list | wc -l); [ "$n" -ge 6100 ] && break; sleep 10; done
echo "$(date -u +%T) fc=$(pgrep -c firecracker) netns=$(sudo ip netns list | wc -l) runner=$(systemctl is-active rlp-runner) memavail=$(awk '/MemAvailable/{printf "%d",$2/1048576}' /proc/meminfo)GiB"
sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "select id,status from runners"
