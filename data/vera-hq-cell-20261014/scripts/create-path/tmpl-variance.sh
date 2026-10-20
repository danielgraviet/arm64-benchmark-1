#!/bin/bash
# Per-template variance for the post-resume guest oops (daytona/rlp#3213): is the risk a property of the
# TEMPLATE BUILD rather than of the clone? For each iteration: delete the cached templates, let one cold boot
# rebuild them, then clone N and scan every guest's serial log for a kernel oops (sandboxes are kept alive).
set -u
S=/home/daytona/steps; API=http://127.0.0.1:8088; N=${N:-300}; ITERS=${ITERS:-5}
OUT=/mnt/data/bench/tmplvar-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT/traces; sudo chown -R $(id -u):$(id -g) $OUT
K=$(grep -oP '^VERA_RLP_API_KEY=\K.*' /home/daytona/arm64-benchmark-1/.env | tr -d '"')
IMG=dtgraviet/vera-agent-benchmark:v3
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
clean() { local i; for i in $(seq 1 90); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id & done; wait
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done; say "WARN firecrackers left"; }
burst() { ( cd $S && ulimit -n 1048576 && ~/arm64-benchmark-1/.venv/bin/python stepclient.py --mode burst --count $1 \
    --procs 16 --image $IMG --out $2 ) > $2.log 2>&1
  python3 -c "import json,sys;s=[json.loads(l) for l in open(sys.argv[1])][-1];print('ok=%d failed=%d'%(s['ok'],s['failed']))" $2 2>/dev/null; }
scan() { # $1 iter -> count oopsed guests, keep one trace per guest
  sudo bash -c "t=0; n=0
    for f in /run/fc/*/serial.log; do [ -f \"\$f\" ] || continue; t=\$((t+1))
      if grep -qE 'Internal error: Oops|Unable to handle kernel|Kernel panic|BUG: ' \"\$f\"; then
        n=\$((n+1)); cp \"\$f\" $OUT/traces/iter$1-\$(basename \$(dirname \"\$f\")).log; fi; done
    echo \"\$n/\$t\""; }
trap 'clean; sudo chown -R $(id -u):$(id -g) $OUT 2>/dev/null; say "EXIT"' EXIT
for i in $(seq 1 $ITERS); do
  clean
  sudo rm -rf /mnt/data/rlp/scratch/snapshots/* 2>/dev/null
  sleep 2
  cold=$(burst 4 $OUT/cold-$i.jsonl)                     # cold boots rebuild the template
  sleep 8; clean; sleep 2
  res=$(burst $N $OUT/clones-$i.jsonl)                   # clones of THIS template build
  sleep 15                                               # let any post-resume oops land
  o=$(scan $i)
  key=$(sudo ls /mnt/data/rlp/scratch/snapshots | head -1 | cut -c1-12)
  say "iter $i: template=$key cold:[$cold] clones:[$res] oopsed_guests=$o"
  clean
done
say "traces captured: $(ls $OUT/traces/*.log 2>/dev/null | wc -l)"
for f in $OUT/traces/*.log; do [ -f "$f" ] || continue
  echo "=== $(basename $f)"; grep -m1 -B3 -A30 -E "Internal error: Oops|Unable to handle kernel|BUG: " "$f"; done >> $OUT/traces-summary.txt 2>/dev/null
echo $OUT
