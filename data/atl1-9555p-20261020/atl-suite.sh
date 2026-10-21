#!/bin/bash
# atl1node853 (EPYC 9555P, 1 socket 64C/128T): the baseline suite with the create-path fixes ON, same commands and
# settings as BASELINE-VERA/EPYC9575-FIXES-20261014 (+ the 2,000-sandbox runs). Run as root.
#   A. startup 1,000: idle x3, agent x3          (mpfleet --procs 16)
#   B. dense ladder 176 352 704                  (read timeout 600 s, as in the 9575F 704 rerun)
#   C. startup 2,000: idle x3, agent x2; dense ladder level 2000 (exec + read timeout 1,800 s)
# Other cells: override T (harness target), BD (harness checkout with .venv and .env), API, PGC (postgres container).
# Needs: bench-preflight on PATH (scripts/host/bench-preflight.sh), the fixes ON (patches/bench-build + fixes-on.sh).
set -u
ulimit -n 1048576
BD=${BD:-/home/ubuntu/arm64-benchmark-1}; API=${API:-http://127.0.0.1:8088}; T=${T:-atl1}; PGC=${PGC:-rlp-postgres}; PY=$BD/.venv/bin/python
AGENT=dtgraviet/vera-agent-benchmark:v3; IDLE=alpine:3.20
OUT=/mnt/data/bench/suite-$T-$(date -u +%Y%m%d_%H%M%S); mkdir -p $OUT
K=$(grep -oP '^RLP_API_KEY=\K.*' $BD/.env)
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
PG() { docker exec -i $PGC psql -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
clean() { local i; for i in $(seq 1 120); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id & done; wait
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done; say "WARN $(pgrep -c firecracker) firecrackers left"; }
preflight() { local pf=$OUT/pf-$1; for w in $(seq 1 30); do bench-preflight $pf >/dev/null 2>&1 && break; sleep 10; done
  echo "$(grep -q 'PREFLIGHT PASS' $pf/preflight.txt && echo PASS || echo "FAIL:$(grep FAIL $pf/preflight.txt | awk '{print $1}' | tr '\n' ',')") fixes=$(grep -oP 'create_path_fixes\s+INFO\s+\K\S+' $pf/preflight.txt)"; }
mon() { while :; do echo "$(date +%s) $(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%.1f %.1f", t/1048576, (t-a)/1048576}' /proc/meminfo) $(cut -d' ' -f1 /proc/loadavg) $(pgrep -c firecracker) $(awk '{s+=$1} END {printf "%.0f", s/NR/1000}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq)"; sleep 5; done > $OUT/mon-$1.txt; }
monsum() { python3 - $OUT/mon-$1.txt <<'PY'
import sys
r=[l.split() for l in open(sys.argv[1]) if len(l.split())==6]
if not r: print("no samples"); raise SystemExit
used=[float(x[2]) for x in r]; fc=[int(x[4]) for x in r]; mhz=[int(x[5]) for x in r if int(x[4])>0] or [0]
print(f"peak mem used {max(used):.0f}/{float(r[0][1]):.0f} GiB (baseline {min(used):.0f}); peak load {max(float(x[3]) for x in r):.0f}; peak live {max(fc)}; mean MHz while busy {sum(mhz)/len(mhz):.0f}")
PY
}
fleet() { # $1 image $2 count $3 out $4 read-timeout
  ( cd $BD && set -a && . ./.env && set +a && export PYTHONUNBUFFERED=1 RLP_HTTP_MAX_CONNECTIONS=1024 RLP_HTTP_READ_TIMEOUT_S=$4 \
      RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0 MPFLEET_IMAGE=$1 && \
    timeout 1200 $PY mpfleet.py --target $T --procs 16 --count $2 --timeout 300 --output $3 ) > $3.log 2>&1
  python3 -c "import json,sys;s=[json.loads(l) for l in open(sys.argv[1])][-1];print('ok=%d failed=%d all_ready=%.2fs create_p50=%.2fs p95=%.2fs post_p50=%.2fs'%(s['ok'],s['failed'],s['ready_wall_s'],s['create_p50_s'],s['create_p95_s'],s['post_p50_s']))" $3 2>/dev/null || echo "no-summary"; }
startup() { # $1 count $2 label $3 image $4 rep $5 read-timeout
  clean; sleep 2; local tag=$1-$2-$4 pf; pf=$(preflight $tag)
  local a=$(nstat -az TcpExtListenOverflows | tail -1 | awk '{print $2}')
  mon s-$tag & local M=$!
  local r=$(fleet $3 $1 $OUT/startup-$tag.jsonl $5)
  sleep 5; kill $M 2>/dev/null; wait $M 2>/dev/null
  local b=$(nstat -az TcpExtListenOverflows | tail -1 | awk '{print $2}')
  say "STARTUP n=$1 image=$2 rep=$4 $r overflows=$((b-a)) preflight=$pf | $(monsum s-$tag)"
  python3 -c "
import json,sys,collections
c=collections.Counter((json.loads(l).get('error') or '')[:100] for l in open(sys.argv[1]) if '\"status\": \"failed\"' in l)
[print('   failure x%d: %s'%(n,e)) for e,n in c.most_common(3)]" $OUT/startup-$tag.jsonl 2>/dev/null | tee -a $OUT/log; }
ladder() { # $1 name $2 levels $3 exec/read timeout
  clean; local pf; pf=$(preflight $1)
  mon $1 & local M=$!
  ( cd $BD && set -a && . ./.env && set +a && export PYTHONUNBUFFERED=1 RLP_HTTP_MAX_CONNECTIONS=512 RLP_HOLD_CREATE_BATCH=512 RLP_HTTP_READ_TIMEOUT_S=$3 && \
    timeout 7200 $PY main.py --benchmark agent --runner rlp --target $T --snapshot $AGENT --exec-timeout $3 \
      --levels $2 --n 45 --seed 42 -E 8 --hold-then-exec --rlp-cpu 0.025 --rlp-cpu-max 1 \
      --rlp-memory 0.0625 --rlp-memory-max 4 --rlp-disk 0.015625 --output $OUT/$1.jsonl ) > $OUT/$1.log 2>&1
  local rc=$?; kill $M 2>/dev/null; wait $M 2>/dev/null
  python3 - $OUT/$1.jsonl <<'PY' | while read l; do say "TPUT $l"; done
import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r.get("type")=="summary":
        print(f"c={r['concurrency']} runs={r['runs']} failures={r['failures']} tput={r['throughput_per_sec']}/s p50={r['p50_ms']/1000:.1f}s p95={r['p95_ms']/1000:.1f}s p99={r['p99_ms']/1000:.1f}s max={r['max_ms']/1000:.1f}s")
PY
  say "   $1 exit=$rc preflight=$pf | $(monsum $1)"; }
trap 'rc=$?; clean; say "EXIT rc=$rc"' EXIT
say "host=$(hostname) $(lscpu | grep 'Model name' | head -1 | sed 's/ \+/ /g') nproc=$(nproc) kernel=$(uname -r) runner=$(sha256sum /usr/local/bin/rlp-runner | cut -c1-12) api=$(sha256sum /usr/local/bin/rlp-api | cut -c1-12) slice=$(cat /sys/fs/cgroup/rlp.slice/cpuset.cpus.effective)"
cp /etc/rlp/HOSTCHANGES $OUT/HOSTCHANGES.at-start
clean; for img in $IDLE $AGENT; do for w in 1 2; do fleet $img 10 $OUT/warm-$(basename $img | tr ':/' '__')-$w.jsonl 120 >/dev/null; clean; done; done
say "=== A. startup 1,000"
for r in 1 2 3; do startup 1000 idle $IDLE $r 120; startup 1000 agent $AGENT $r 120; done
say "=== B. dense ladder 176 352 704"
ladder ladder-176-704 "176 352 704" 600
say "=== C. 2,000"
for r in 1 2 3; do startup 2000 idle $IDLE $r 1800; done
for r in 1 2; do startup 2000 agent $AGENT $r 1800; done
ladder ladder-2000 "2000" 1800
say "DONE -> $OUT"
