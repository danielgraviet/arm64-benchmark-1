SL=/sys/fs/cgroup/rlp.slice
echo 0-191 | sudo tee $SL/cpuset.cpus $SL/vms/cpuset.cpus >/dev/null; echo 0-1 | sudo tee $SL/cpuset.mems $SL/vms/cpuset.mems >/dev/null
echo "slice=$(cat $SL/cpuset.cpus.effective) mems=$(cat $SL/cpuset.mems.effective)"
K=$(sudo cat /etc/rlp/bench-api-key)
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
echo "live rows: $(PG "select status||'='||count(*) from vms where status not in ('deleted') group by status" | tr '\n' ' ')"
for i in $(seq 1 40); do
  for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" http://127.0.0.1:8088/vms/$id & done; wait
  n=$(pgrep -c firecracker); [ "$n" = 0 ] && break; sleep 10; done
echo "firecracker left: $(pgrep -c firecracker)  live rows: $(PG "select status||'='||count(*) from vms where status not in ('deleted') group by status" | tr '\n' ' ')"
echo "$(date -u +%FT%TZ) recovery after 64k PIN-N0 node-0 OOM at c=1408: unpinned rlp.slice, deleted leftover sandboxes" | sudo tee -a /etc/rlp/HOSTCHANGES >/dev/null
