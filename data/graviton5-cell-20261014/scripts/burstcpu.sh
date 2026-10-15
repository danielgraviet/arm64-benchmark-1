# CPU accounting for one 1k create-ready burst (UNPIN): per-cgroup usage_usec deltas + whole-host /proc/stat.
set -u
cd ~/arm64-benchmark-1 && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 && set -a && . ./.env && set +a && ulimit -n 1048576
export RLP_HTTP_MAX_CONNECTIONS=1024 RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0
IMG=${IMG:-dtgraviet/vera-agent-benchmark:v3}; N=${N:-1000}
OUT=/mnt/data/bench/burstcpu-$(date -u +%H%M%S); mkdir -p $OUT
cg() { for c in rlp.slice/vms rlp.slice/rlp-runner.service system.slice/rlp-api.service system.slice/rlp-proxy.service system.slice/docker.service user.slice; do
  printf "%s=%s " $c $(sudo awk '/usage_usec/{print $2}' /sys/fs/cgroup/$c/cpu.stat 2>/dev/null || echo 0); done; }
pst() { awk '/^cpu /{print $2+$3+$4+$6+$7+$8, $5}' /proc/stat; }
# postgres runs as a docker container scope
pgcg=$(sudo find /sys/fs/cgroup/system.slice -maxdepth 1 -name "docker-$(sudo docker inspect -f '{{.Id}}' rlp-postgres)*.scope" | head -1)
b0=$(cg); s0=$(pst); pg0=$(sudo awk '/usage_usec/{print $2}' $pgcg/cpu.stat); t0=$(date +%s.%N)
uv run python scripts/rlp_light_create_fleet.py --target graviton5 --count $N --workers $N --image $IMG --cpu 0.025 --memory 0.0625 --disk 1.0 --probe 'echo ready' --keep --output $OUT/fleet.jsonl > $OUT/fleet.log 2>&1
t1=$(date +%s.%N); b1=$(cg); s1=$(pst); pg1=$(sudo awk '/usage_usec/{print $2}' $pgcg/cpu.stat)
sleep 20; b2=$(cg); t2=$(date +%s.%N)
python3 - "$b0" "$b1" "$b2" "$s0" "$s1" "$t0" "$t1" "$t2" "$pg0" "$pg1" <<'PY'
import sys
p=lambda s: {kv.split("=")[0]:int(kv.split("=")[1]) for kv in s.split()}
b0,b1,b2=p(sys.argv[1]),p(sys.argv[2]),p(sys.argv[3])
s0,s1=[list(map(int,x.split())) for x in sys.argv[4:6]]; t0,t1,t2=map(float,sys.argv[6:9]); pg0,pg1=int(sys.argv[9]),int(sys.argv[10])
wall=t1-t0; hz=100
busy=(s1[0]-s0[0])/hz; idle=(s1[1]-s0[1])/hz
print(f"burst wall={wall:.1f}s  host busy={busy:.0f} core-s  idle={idle:.0f} core-s  avg busy cores={busy/wall:.0f} of 192")
for k in b0: print(f"  {k:32} burst={(b1[k]-b0[k])/1e6:8.0f} core-s   +20s after={(b2[k]-b1[k])/1e6:7.0f} core-s")
print(f"  {'postgres container':32} burst={(pg1-pg0)/1e6:8.0f} core-s")
PY
grep -m1 '"type": *"summary"' $OUT/fleet.jsonl | grep -oE '"(ok|failed|ready_wall_s)": *[0-9.]+' | tr '\n' ' '; echo
K=$(sudo cat /etc/rlp/bench-api-key)
for id in $(sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" http://127.0.0.1:8088/vms/$id & done; wait
for i in $(seq 1 60); do [ "$(pgrep -c firecracker)" = 0 ] && break; sleep 5; done; echo "fc left=$(pgrep -c firecracker)"
