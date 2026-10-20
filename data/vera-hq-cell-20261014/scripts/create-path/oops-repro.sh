#!/bin/bash
# Reproduce the post-resume guest oops with the agent image and KEEP the sandboxes so serial logs survive.
set -u
S=/home/daytona/steps; API=http://127.0.0.1:8088
OUT=/mnt/data/bench/oops-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(grep -oP '^VERA_RLP_API_KEY=\K.*' /home/daytona/arm64-benchmark-1/.env | tr -d '"')
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
clean() { local i; for i in $(seq 1 90); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id & done; wait
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done; }
scan() { # $1 rep
  sudo bash -c "
    t=0; n=0
    for f in /run/fc/*/serial.log; do
      [ -f \"\$f\" ] || continue; t=\$((t+1))
      if grep -qE 'Internal error: Oops|Unable to handle kernel|Kernel panic|BUG:' \"\$f\"; then
        n=\$((n+1)); d=\$(dirname \"\$f\")
        cp \"\$f\" $OUT/serial-$1-\$(basename \$d).log
      fi
    done
    echo \"rep$1: oopsed=\$n of \$t live guests\"" | tee -a $OUT/log
}
for r in 1 2; do
  clean; sleep 3
  ( cd $S && ulimit -n 1048576 && ~/arm64-benchmark-1/.venv/bin/python stepclient.py --mode burst --count 1000 --procs 16 \
      --image dtgraviet/vera-agent-benchmark:v3 --out $OUT/client-$r.jsonl ) > $OUT/client-$r.log 2>&1
  echo "rep$r client: $(tail -1 $OUT/client-$r.log)" | tee -a $OUT/log
  sleep 20   # let the entrypoint workload run and any late oops land
  scan $r
  # vcpu shape + daemon reachability of the failed ones
  python3 -c "
import json,sys
bad=[json.loads(l) for l in open(sys.argv[1]) if '\"status\": \"failed\"' in l]
print('rep$r failed sandboxes:', len(bad))
for b in bad[:6]: print('   ', b.get('vm_id','?')[:8], (b.get('error') or '')[:90])" $OUT/client-$r.jsonl | tee -a $OUT/log
done
PG "select vcpus, count(*) from vms where created_at > now() - interval '20 min' group by 1" | tee -a $OUT/log
clean
sudo chown -R $(id -u):$(id -g) $OUT
echo "traces: $(ls $OUT/serial-*.log 2>/dev/null | wc -l)" | tee -a $OUT/log
echo $OUT
