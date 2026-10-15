#!/bin/bash
set -u
API=http://127.0.0.1:8088; K=$(sudo cat /etc/rlp/bench-api-key)
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
echo "$(date -u +%T) start fc=$(pgrep -c firecracker)"
for i in $(seq 1 300); do
  ids=$(PG "select id from vms where status not in ('deleted','failed','lost') limit 2000")
  [ -z "$ids" ] && [ "$(pgrep -c firecracker)" = 0 ] && break
  echo "$ids" | xargs -r -P 32 -I{} curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/{}
  [ $((i % 10)) = 0 ] && echo "$(date -u +%T) fc=$(pgrep -c firecracker) live=$(PG "select count(*) from vms where status='running'")"
  sleep 3
done
echo "$(date -u +%T) done fc=$(pgrep -c firecracker) memavail=$(awk '/MemAvailable/{printf "%d",$2/1048576}' /proc/meminfo)GiB"
