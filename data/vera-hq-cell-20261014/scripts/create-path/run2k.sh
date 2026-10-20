#!/bin/bash
# 2,000-sandbox runs, fixes ON (current reference state), identical on HQ Vera and the EPYC 9575F.
#   startup:    mpfleet.py --procs 16 --count 2000; idle image x3, agent image x2
#   throughput: dense ladder at level 2000 (n=45, -E 8, hold-then-exec) = 16,000 episodes
# Job timeout and client read timeout raised to 1800 s on both hosts so slow-but-healthy episodes at this
# density are not counted as failures (expected ~250 s per episode on the 9575F). Host memory/load sampled
# every 5 s. usage: run2k.sh <vera|epyc9575>
set -u
HOST=$1
if [ $HOST = vera ]; then BD=/home/daytona/arm64-benchmark-1; T=vera; KEYVAR=VERA_RLP_API_KEY; SUDO=sudo
  PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
  PREFLIGHT="sudo /usr/local/bin/bench-preflight"
else BD=/home/ubuntu/arm64-benchmark-1; T=epyc9575; KEYVAR=RLP_API_KEY; SUDO=
  PG() { docker exec -i rlp-postgres psql -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
  PREFLIGHT="bash $BD/scripts/host/bench-preflight.sh"
fi
PY=$BD/.venv/bin/python; API=http://127.0.0.1:8088
AGENT=dtgraviet/vera-agent-benchmark:v3; IDLE=alpine:3.20; TO=1800
OUT=/mnt/data/bench/run2k-$HOST-$(date -u +%Y%m%d_%H%M%S); $SUDO mkdir -p $OUT; $SUDO chown $(id -u):$(id -g) $OUT
K=$(grep -oP "^$KEYVAR=\\K.*" $BD/.env | tr -d '"')
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
clean() { local i; for i in $(seq 1 120); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id & done; wait
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done; say "WARN $(pgrep -c firecracker) firecrackers left"; }
mon() { # $1 tag: host memory + load + live sandboxes every 5 s, until killed
  while :; do echo "$(date +%s) $(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%.1f %.1f", t/1048576, (t-a)/1048576}' /proc/meminfo) $(cut -d' ' -f1 /proc/loadavg) $(pgrep -c firecracker)"; sleep 5; done > $OUT/mon-$1.txt; }
monsum() { python3 - $OUT/mon-$1.txt <<'PY'
import sys
r=[l.split() for l in open(sys.argv[1]) if len(l.split())==5]
if not r: print("no samples"); raise SystemExit
used=[float(x[2]) for x in r]; load=[float(x[3]) for x in r]; fc=[int(x[4]) for x in r]
print(f"peak host mem used {max(used):.0f} of {float(r[0][1]):.0f} GiB ({100*max(used)/float(r[0][1]):.0f}%), baseline {min(used):.0f} GiB; peak load {max(load):.0f}; peak live sandboxes {max(fc)}")
PY
}
preflight() { local pf=$OUT/pf-$1; for w in $(seq 1 30); do $PREFLIGHT $pf >/dev/null 2>&1 && break; sleep 10; done
  $SUDO chown -R $(id -u):$(id -g) $pf 2>/dev/null
  echo "$(grep -q 'PREFLIGHT PASS' $pf/preflight.txt && echo PASS || echo FAIL) fixes=$(grep -oP 'create_path_fixes\s+INFO\s+\K\S+' $pf/preflight.txt)"; }
fleet() { # $1 image $2 count $3 out
  ( cd $BD && set -a && . ./.env && set +a && export RLP_API_URL=$API RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox \
      VERA_RLP_API_URL=$API VERA_RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox PYTHONUNBUFFERED=1 \
      RLP_HTTP_MAX_CONNECTIONS=1024 RLP_HTTP_READ_TIMEOUT_S=$TO RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 \
      RLP_WAIT_POLL_MAX_S=2.0 MPFLEET_IMAGE=$1 && ulimit -n 1048576 && \
    timeout 1200 $PY mpfleet.py --target $T --procs 16 --count $2 --timeout 300 --output $3 ) > $3.log 2>&1
  python3 -c "import json,sys;s=[json.loads(l) for l in open(sys.argv[1])][-1];print('ok=%d failed=%d all_ready=%.2fs create_p50=%.2fs p95=%.2fs post_p50=%.2fs'%(s['ok'],s['failed'],s['ready_wall_s'],s['create_p50_s'],s['create_p95_s'],s['post_p50_s']))" $3 2>/dev/null || echo "no-summary: $(tail -1 $3.log | cut -c1-150)"; }
startup() { # $1 label $2 image $3 rep
  clean; sleep 2; local pf=$(preflight $1-$3)
  local a=$(nstat -az TcpExtListenOverflows | tail -1 | awk '{print $2}')
  mon s-$1-$3 & local M=$!
  local r=$(fleet $2 2000 $OUT/startup-$1-$3.jsonl)
  sleep 10; kill $M 2>/dev/null; wait $M 2>/dev/null
  local b=$(nstat -az TcpExtListenOverflows | tail -1 | awk '{print $2}')
  say "STARTUP2K image=$1 rep=$3 $r overflows=$((b-a)) preflight=$pf"
  say "   $(monsum s-$1-$3)"
  # failures: what kind
  python3 -c "
import json,sys,collections
c=collections.Counter((json.loads(l).get('error') or '')[:90] for l in open(sys.argv[1]) if '\"status\": \"failed\"' in l)
[print('   failure x%d: %s'%(n,e)) for e,n in c.most_common(4)]" $OUT/startup-$1-$3.jsonl | tee -a $OUT/log
}
tput() {
  clean; local pf=$(preflight tput)
  mon tput & local M=$!
  ( cd $BD && set -a && . ./.env && set +a && \
    export RLP_API_URL=$API RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox VERA_RLP_API_URL=$API \
           VERA_RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox VERA_RLP_TARGET=vera PYTHONUNBUFFERED=1 \
           RLP_HTTP_MAX_CONNECTIONS=512 RLP_HOLD_CREATE_BATCH=512 RLP_HTTP_READ_TIMEOUT_S=$TO && ulimit -n 1048576 && \
    timeout 7200 $PY main.py --benchmark agent --runner rlp --target $T --snapshot $AGENT --exec-timeout $TO \
      --levels 2000 --n 45 --seed 42 -E 8 --hold-then-exec --rlp-cpu 0.025 --rlp-cpu-max 1 \
      --rlp-memory 0.0625 --rlp-memory-max 4 --rlp-disk 0.015625 --output $OUT/tput-2000.jsonl ) > $OUT/tput-2000.log 2>&1
  local rc=$?
  kill $M 2>/dev/null; wait $M 2>/dev/null
  python3 - $OUT/tput-2000.jsonl <<'PY' | while read l; do say "TPUT2K $l"; done
import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r.get("type")=="summary":
        print(f"c={r['concurrency']} runs={r['runs']} failures={r['failures']} tput={r['throughput_per_sec']}/s p50={r['p50_ms']/1000:.1f}s p95={r['p95_ms']/1000:.1f}s p99={r['p99_ms']/1000:.1f}s max={r['max_ms']/1000:.1f}s")
PY
  say "   ladder exit=$rc preflight=$pf; $(monsum tput)"
}
trap 'rc=$?; clean; say "EXIT rc=$rc"' EXIT
say "host=$HOST $(lscpu | grep 'Model name' | head -1 | sed 's/ \+/ /g') nproc=$(nproc) runner=$(sha256sum /usr/local/bin/rlp-runner | cut -c1-12)"
for r in 1 2 3; do startup idle $IDLE $r; done
for r in 1 2; do startup agent $AGENT $r; done
tput
say "DONE -> $OUT"
