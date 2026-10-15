#!/bin/bash
# Re-run the dense ladder at level 704, fixes OFF then ON, with a 600 s client read timeout (= the harness exec
# timeout). The first pass used 120 s, which cut off healthy-but-slow level-704 episodes on the 9575F
# (p50 83 s there). Toggles the persistent 20-create-path-fixes.conf drop-ins; leaves the fixes ON.
#   usage: tput704.sh <vera|epyc9575>
set -u
HOST=$1
if [ $HOST = vera ]; then BD=/home/daytona/arm64-benchmark-1; T=vera; KEYVAR=VERA_RLP_API_KEY; SUDO=sudo; PY="$BD/.venv/bin/python"
  PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
else BD=/home/ubuntu/arm64-benchmark-1; T=epyc9575; KEYVAR=RLP_API_KEY; SUDO=; PY="$BD/.venv/bin/python"
  PG() { docker exec -i rlp-postgres psql -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
fi
API=http://127.0.0.1:8088; AGENT=dtgraviet/vera-agent-benchmark:v3
OUT=/mnt/data/bench/tput704-$HOST-$(date -u +%Y%m%d_%H%M%S); $SUDO mkdir -p $OUT; $SUDO chown $(id -u):$(id -g) $OUT
K=$(grep -oP "^$KEYVAR=\\K.*" $BD/.env | tr -d '"')
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
clean() { local i; for i in $(seq 1 90); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id & done; wait
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done; }
setfix() { # on|off : move the persistent drop-ins aside for OFF
  for u in runner api; do d=/etc/systemd/system/rlp-$u.service.d
    if [ $1 = on ]; then $SUDO test -e $d/20-create-path-fixes.conf.off && $SUDO mv $d/20-create-path-fixes.conf.off $d/20-create-path-fixes.conf
    else $SUDO test -e $d/20-create-path-fixes.conf && $SUDO mv $d/20-create-path-fixes.conf $d/20-create-path-fixes.conf.off; fi; done
  clean; $SUDO find /sys/fs/cgroup/rlp.slice/vms -maxdepth 1 -name 'vm-pool-*' -exec rmdir {} + 2>/dev/null
  $SUDO systemctl daemon-reload; $SUDO systemctl restart rlp-api; sleep 3; $SUDO systemctl restart rlp-runner
  for i in $(seq 1 120); do curl -fsS -m 2 $API/health >/dev/null 2>&1 && break; sleep 1; done
  local ok=0; for i in $(seq 1 180); do n=$($SUDO ip netns list 2>/dev/null | wc -l)
    if [ "$n" -ge 1995 ]; then ok=$((ok+1)); [ $ok -ge 2 ] && break; else ok=0; fi; sleep 10; done
  sleep 5
  local pf=$OUT/pf-$1; for w in $(seq 1 30); do $SUDO bash $BD/scripts/host/bench-preflight.sh $pf >/dev/null 2>&1 && break; sleep 10; done
  $SUDO chown -R $(id -u):$(id -g) $pf 2>/dev/null
  say "FIXES $1: $(grep -oP 'create_path_fixes\s+INFO\s+\K.*' $pf/preflight.txt)  preflight=$(grep -q 'PREFLIGHT PASS' $pf/preflight.txt && echo PASS || echo FAIL)"
}
trap 'rc=$?; setfix on >/dev/null 2>&1; clean; say "EXIT rc=$rc (fixes ON)"' EXIT
for f in off on; do
  setfix $f
  ( cd $BD && set -a && . ./.env && set +a && \
    export RLP_API_URL=$API RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox VERA_RLP_API_URL=$API \
           VERA_RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox VERA_RLP_TARGET=vera PYTHONUNBUFFERED=1 \
           RLP_HTTP_MAX_CONNECTIONS=512 RLP_HOLD_CREATE_BATCH=512 RLP_HTTP_READ_TIMEOUT_S=600 && ulimit -n 1048576 && \
    timeout 3600 $PY main.py --benchmark agent --runner rlp --target $T --snapshot $AGENT \
      --levels 704 --n 45 --seed 42 -E 8 --hold-then-exec --rlp-cpu 0.025 --rlp-cpu-max 1 \
      --rlp-memory 0.0625 --rlp-memory-max 4 --rlp-disk 0.015625 --output $OUT/tput704-$f.jsonl ) > $OUT/tput704-$f.log 2>&1
  python3 - $OUT/tput704-$f.jsonl <<'PY' | while read l; do say "TPUT704 fixes=$f $l"; done
import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r.get("type")=="summary":
        print(f"c={r['concurrency']} runs={r['runs']} failures={r['failures']} tput={r['throughput_per_sec']}/s p50={r['p50_ms']/1000:.1f}s p99={r['p99_ms']/1000:.1f}s max={r['max_ms']/1000:.1f}s")
PY
done
say "DONE -> $OUT"
