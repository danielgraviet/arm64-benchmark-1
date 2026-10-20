#!/bin/bash
# EPYC 9575F (1 socket, 64C/128T): 1k burst, agent image (entrypoint = workload.agent, CPU-bound) vs alpine (idle),
# interleaved, mpfleet --procs 16, 0.5 s CPU accounting (host busy %, rlp.slice/vms cores). Run as root.
set -u
T=epyc9575; BD=/home/ubuntu/arm64-benchmark-1; API=http://127.0.0.1:8088; SL=/sys/fs/cgroup/rlp.slice
OUT=/mnt/data/bench/entry-ab-9575-$(date -u +%Y%m%d_%H%M%S); mkdir -p $OUT
K=$(grep -oP "^RLP_API_KEY=\K.*" /home/ubuntu/arm64-benchmark-1/.env)
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
PG() { docker exec -i rlp-postgres psql -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
clean() { local i; for i in $(seq 1 60); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id & done; wait
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done; say "WARN $(pgrep -c firecracker) firecrackers left"; }
fleet() { # $1 image $2 count $3 out
  ( cd $BD && set -a && . ./.env && set +a && export RLP_API_URL=$API RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox \
      PYTHONUNBUFFERED=1 RLP_HTTP_MAX_CONNECTIONS=1024 RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0 \
      MPFLEET_IMAGE=$1 && ulimit -n 1048576 && timeout 600 $BD/.venv/bin/python mpfleet.py --target $T --procs 16 --count $2 --output $3 ) > $3.log 2>&1
  python3 -c "import json,sys;s=[json.loads(l) for l in open(sys.argv[1])][-1];print('ok=%d failed=%d wall=%.2f p50=%.2f p95=%.2f post_p50=%.2f'%(s['ok'],s['failed'],s['ready_wall_s'],s['create_p50_s'],s['create_p95_s'],s['post_p50_s']))" $3 2>/dev/null || echo "no-summary: $(tail -2 $3.log)"; }
sampler() { python3 - $1 $SL <<'PY' &
import sys,time
out,sl=sys.argv[1:3]
def stat():
    for l in open("/proc/stat"):
        if l.startswith("cpu "):
            v=list(map(int,l.split()[1:9])); return sum(v)-v[3]-v[4], sum(v)
def us(p):
    try:
        for l in open(p+"/cpu.stat"):
            if l.startswith("usage_usec"): return int(l.split()[1])
    except Exception: return 0
    return 0
with open(out,"w") as fh:
    fh.write("t\tbusy_pct\tvms_cores\n"); b0,t0=stat(); v0=us(sl+"/vms"); T0=tp=time.time()
    for _ in range(80):
        time.sleep(0.5); b,t=stat(); v=us(sl+"/vms"); now=time.time()
        fh.write(f"{now-T0:.1f}\t{100*(b-b0)/max(1,t-t0):.1f}\t{(v-v0)/1e6/(now-tp):.1f}\n"); fh.flush(); b0,t0,v0,tp=b,t,v,now
PY
}
A=dtgraviet/vera-agent-benchmark:v3; B=alpine:3.20
say "host: $(lscpu | grep 'Model name' | head -1 | sed 's/ \+/ /g') nproc=$(nproc) runner_sha=$(sha256sum $(readlink -f /proc/$(pgrep -nx rlp-runner)/exe) | cut -c1-12) floor=$(pgrep -fc rlp-cpu-weight-floor || true)"
for img in $A $B; do clean; say "warm $img: $(fleet $img 10 $OUT/warm-$(basename $img | tr ':/' '__').jsonl)"; clean; say "warm2 $img: $(fleet $img 10 $OUT/warm2-$(basename $img | tr ':/' '__').jsonl)"; done
i=0
for spec in "AGENT $A" "ALPINE $B" "AGENT $A" "ALPINE $B" "ALPINE $B" "AGENT $A"; do
  set -- $spec; i=$((i+1)); name=$i-$1; clean; sleep 3
  for w in $(seq 1 30); do bash $BD/scripts/host/bench-preflight.sh $OUT/pf-$name >/dev/null 2>&1 && break; sleep 10; done
  pf=$(grep -c FAIL $OUT/pf-$name/preflight.txt 2>/dev/null || echo "?")
  sampler $OUT/$name.cpu.tsv; SP=$!; sleep 2
  res=$(fleet $2 1000 $OUT/$name.jsonl); wait $SP
  cpu=$(awk -F'\t' 'NR>1 {n++; v+=$3; if($3>m)m=$3; if($2>95)s++} END {printf "vms_cores mean=%.0f peak=%.0f; host>95%% busy for %.1fs", v/n, m, s*0.5}' $OUT/$name.cpu.tsv)
  say "$name $res | $cpu | preflight_fails=$pf"
done
clean; say "DONE -> $OUT"
