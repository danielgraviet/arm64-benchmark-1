#!/bin/bash
# Is "accept" (post_s) the benchmark client? Same 1000-sandbox burst from 1 / 4 / 8 / 16 client processes.
# Layout = A-REF (runner+sandboxes on socket 0; control plane + client unpinned). 1 proc = control for the wrapper.
set -u
BD=/home/daytona/arm64-benchmark-1; API=http://127.0.0.1:8088; SL=/sys/fs/cgroup/rlp.slice
OUT=/mnt/data/bench/client-split-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(sudo cat /etc/rlp/bench-api-key)
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
clean() { local i; for i in $(seq 1 60); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id; done
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done
  say "WARN killing $(pgrep -c firecracker) orphans"; sudo pkill -x firecracker; sleep 5; sudo rm -rf /run/fc/* 2>/dev/null
  PG "update vms set status='deleted' where status not in ('deleted','failed','lost')" >/dev/null; }
pin() { echo "$1" | sudo tee $SL/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/cpuset.mems >/dev/null
  [ -d $SL/vms ] && { echo "$1" | sudo tee $SL/vms/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/vms/cpuset.mems >/dev/null; }; }
run() { # procs rep
  ( cd $BD && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 RLP_HTTP_MAX_CONNECTIONS=1024 \
      RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0 && set -a && . ./.env && set +a && ulimit -n 1048576 && \
    timeout 600 uv run python mpfleet.py --procs $1 --count 1000 --output $OUT/p$1-rep$2.jsonl ) > $OUT/p$1-rep$2.log 2>&1
  python3 - $OUT/p$1-rep$2.jsonl <<'PY'
import json,sys
try: s=[json.loads(l) for l in open(sys.argv[1])][-1]
except Exception as e: print("no-summary", e); sys.exit()
print(f"ok={s['ok']}/{s['sandboxes_requested']} wall={s['ready_wall_s']:.2f} skew={s['start_skew_s']*1000:.0f}ms create p50={s['create_p50_s']:.2f} p95={s['create_p95_s']:.2f} | ACCEPT(post) p50={s['post_p50_s']:.2f} p95={s['post_p95_s']:.2f} | wait p50={s['wait_p50_s']:.2f} probe p50={s['probe_p50_s']*1000:.0f}ms")
PY
}
trap 'pin 0-351 0-1; clean; say "restored (slice=$(cat $SL/cpuset.cpus.effective))"' EXIT
pin 0-87,176-263 0; say "layout: runner+sandboxes socket 0 ($(cat $SL/cpuset.cpus.effective)); control plane + client unpinned"
for p in 1 4 8 16; do
  for r in 1 2 3; do
    clean; ok=0; for w in $(seq 1 30); do sudo /usr/local/bin/bench-preflight $OUT/pf-p$p-$r >/dev/null && { ok=1; break; }; sleep 10; done
    [ $ok = 1 ] || { say "PREFLIGHT FAIL p$p rep$r"; continue; }
    say "procs=$p rep$r $(run $p $r)"
  done
done
say "DONE -> $OUT"
