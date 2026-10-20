#!/bin/bash
# True holding capacity of phoenix-e6: add sandboxes in waves that each fit inside the hard
# 60 s create-pickup cap (api CREATE_MAX_QUEUE_SECS_CAP), keeping every sandbox alive, until a
# wave fails. A single 5,000-wide burst fails at ~4,000 because of that cap, not the hardware.
set -u
exec 9>/tmp/ph-waves.lock; flock -n 9 || { echo "another ph-waves run holds the lock"; exit 1; }
BD=/home/ubuntu/arm64-benchmark-1; API=http://127.0.0.1:8088
OUT=/mnt/data/bench/waves-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(sudo cat /etc/rlp/bench-api-key)
WAVE=${WAVE:-1000}; MAXW=${MAXW:-8}; DISK=${DISK:-1.0}
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
clean() { local i; for i in $(seq 1 200); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost') limit 4000"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id; done
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done
  say "  WARN killing $(pgrep -c firecracker) orphans"; sudo pkill -x firecracker; sleep 10; sudo rm -rf /run/fc/* 2>/dev/null
  PG "update vms set status='deleted' where status not in ('deleted','failed','lost')" >/dev/null; }
state() { echo "fc=$(pgrep -c firecracker) resv=$(PG "select (capacity->'reserved'->>'MemMiB')||'mem/'||(capacity->'reserved'->>'ScratchMiB')||'scr/'||(capacity->'reserved'->>'Cpu')||'cpu' from runners") live_rows=$(PG "select count(*) from vms where status='running'") memavail_gib=$(awk '/MemAvailable/{printf "%d",$2/1048576}' /proc/meminfo) load1=$(cut -d' ' -f1 /proc/loadavg) netns_free=$(ip netns list | wc -l)"; }

say "=== holding-capacity waves of $WAVE (alpine:3.20, scratch ${DISK} GiB/sandbox, kept alive). caps: $(sudo grep -E '^RLP_(NETNS_POOL|MAX_LIVE_VMS|SUBNET_CIDR)=' /etc/rlp/runner.env | tr '\n' ' ')"
clean; sleep 5
say "baseline $(state)"
tot=0
for w in $(seq 1 $MAXW); do
  f=$OUT/wave$w.jsonl
  t0=$(date +%s.%N)
  ( cd $BD && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 MPFLEET_IMAGE=alpine:3.20 MPFLEET_DISK=$DISK && set -a && . ./.env && set +a && ulimit -n 1048576 && \
    timeout 900 uv run python mpfleet.py --target phoenix-e6 --count $WAVE --procs 16 --timeout 300 --probe-timeout 120 --output $f ) > $f.log 2>&1
  t1=$(date +%s.%N)
  ok=$(grep -o '"ok": [0-9]*' $f.log | tail -1 | grep -oE '[0-9]+'); ok=${ok:-0}
  fail=$(grep -o '"failed": [0-9]*' $f.log | tail -1 | grep -oE '[0-9]+'); fail=${fail:-?}
  wall=$(grep -o '"ready_wall_s": [0-9.]*' $f.log | tail -1 | grep -oE '[0-9.]+')
  tot=$((tot + ok))
  say "wave$w +$WAVE -> ok=$ok failed=$fail wall=${wall:-?}s elapsed=$(printf %.1f $(echo "$t1-$t0" | bc))s cumulative_ok=$tot $(state)"
  if [ "$ok" -lt "$WAVE" ]; then
    say "  first failing wave. reasons:"
    python3 - $f <<'PY' | sed 's/^/    /' | tee -a $OUT/log
import json,sys,collections,re
c=collections.Counter()
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r.get("status")=="failed": c[re.sub(r"[0-9a-f-]{36}","<id>",r.get("error") or "")[:120]]+=1
for k,v in c.most_common(5): print(v,"|",k)
PY
    break
  fi
done
say "PEAK CONCURRENT = $tot sandboxes alive. $(state)"
say "probing liveness of the standing fleet"
( cd $BD && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 && set -a && . ./.env && set +a && \
  uv run python - <<'PY' ) 2>&1 | tail -3 | tee -a $OUT/log
import os, random, time, json, urllib.request
api=os.environ["RLP_API_URL"]; k=os.environ["RLP_API_KEY"]
req=urllib.request.Request(f"{api}/vms?limit=5000", headers={"Authorization":f"Bearer {k}"})
d=json.load(urllib.request.urlopen(req, timeout=60))
rows=d if isinstance(d,list) else d.get("items",d.get("vms",[]))
run=[r for r in rows if r.get("status")=="running"]
print(f"api reports {len(run)} running of {len(rows)} rows returned")
PY
say "DONE -> $OUT (fleet left standing; run the cleanup in the runbook when finished)"
