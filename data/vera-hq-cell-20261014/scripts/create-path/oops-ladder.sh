#!/bin/bash
# Reproduce the post-resume guest oops under the ladder (sandboxes exec the agent workload 8x each).
# A background watcher copies any serial log that oopses, so traces survive the ladder's own teardown.
set -u
BD=/home/daytona/arm64-benchmark-1; API=http://127.0.0.1:8088
OUT=/mnt/data/bench/oopsladder-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(grep -oP '^VERA_RLP_API_KEY=\K.*' $BD/.env | tr -d '"')
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
clean() { local i; for i in $(seq 1 90); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id & done; wait
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done; }
clean
sudo bash -c "mkdir -p $OUT/traces; while :; do
  for f in /run/fc/*/serial.log; do
    [ -f \"\$f\" ] || continue
    d=\$(basename \$(dirname \"\$f\"))
    [ -e $OUT/traces/\$d.log ] && continue
    grep -qE 'Internal error: Oops|Unable to handle kernel|Kernel panic|BUG: ' \"\$f\" && cp \"\$f\" $OUT/traces/\$d.log
  done; sleep 3; done" & W=$!
( cd $BD && export PATH=$HOME/.local/bin:/usr/local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 && set -a && . ./.env && set +a && \
  export RLP_API_URL=$API RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox VERA_RLP_API_URL=$API \
         VERA_RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox VERA_RLP_TARGET=vera RLP_HTTP_MAX_CONNECTIONS=512 \
         RLP_HOLD_CREATE_BATCH=512 RLP_HTTP_READ_TIMEOUT_S=120 && \
  ulimit -n 1048576 && \
  timeout 1800 uv run main.py --benchmark agent --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark:v3 \
    --levels 176 --n 45 --seed 42 -E 8 --hold-then-exec --rlp-cpu 0.025 --rlp-cpu-max 1 \
    --rlp-memory 0.0625 --rlp-memory-max 4 --rlp-disk 0.015625 --output $OUT/ladder.jsonl ) > $OUT/ladder.log 2>&1
sleep 10; sudo kill $W 2>/dev/null; sudo pkill -f "Internal error: Oops" 2>/dev/null
sudo chown -R $(id -u):$(id -g) $OUT
python3 -c "
import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r.get('type')=='summary': print(f\"level {r['concurrency']}: runs={r['runs']} failures={r['failures']} tput={r['throughput_per_sec']}/s p50={r['p50_ms']/1000:.1f}s p99={r['p99_ms']/1000:.1f}s\")" $OUT/ladder.jsonl | tee -a $OUT/log
echo "oopsed guests captured: $(ls $OUT/traces/*.log 2>/dev/null | wc -l)" | tee -a $OUT/log
for f in $OUT/traces/*.log; do [ -f "$f" ] || continue
  echo "--- $(basename $f .log)"; grep -m1 -B2 -A28 -E "Internal error: Oops|Unable to handle kernel|BUG: " "$f"; done | tee -a $OUT/log | head -80
clean
echo $OUT
