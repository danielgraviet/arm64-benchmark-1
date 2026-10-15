#!/bin/bash
# Graviton5 test suite (same recipes as the HQ Vera runs). PHASES: A=1k startup pin A/B, B=client-split, C=throughput ladder.
# Layouts: UNPIN = rlp.slice on both NUMA nodes (0-191, mems 0-1); PIN-N0 = rlp.slice on node 0 (0-95, mems 0).
# Control plane + client always unpinned. Every rep gated by bench-preflight. Output: /mnt/data/bench/suite-<ktag>-<stamp>/
set -u
PHASES=${PHASES:-"A B C"}; KT=${KT:-$(getconf PAGESIZE | sed 's/4096/4k/;s/65536/64k/')}
BD=$HOME/arm64-benchmark-1; API=http://127.0.0.1:8088; SL=/sys/fs/cgroup/rlp.slice; T=graviton5
ALL=0-191; N0=0-95
OUT=/mnt/data/bench/suite-$KT-$(date -u +%Y%m%d_%H%M%S); mkdir -p $OUT
K=$(sudo cat /etc/rlp/bench-api-key)
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
clean() { local i; for i in $(seq 1 60); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id & done; wait
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done
  say "WARN killing $(pgrep -c firecracker) orphans"; sudo pkill -x firecracker; sleep 5
  PG "update vms set status='deleted' where status not in ('deleted','failed','lost')" >/dev/null; }
pin() { # $1 cpus $2 mems
  grep -qw cpuset /sys/fs/cgroup/cgroup.subtree_control || echo +cpuset | sudo tee /sys/fs/cgroup/cgroup.subtree_control >/dev/null
  grep -qw cpuset $SL/cgroup.subtree_control || echo +cpuset | sudo tee $SL/cgroup.subtree_control >/dev/null
  echo "$1" | sudo tee $SL/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/cpuset.mems >/dev/null
  if [ -d $SL/vms ]; then grep -qw cpuset $SL/vms/cgroup.subtree_control || echo +cpuset | sudo tee $SL/vms/cgroup.subtree_control >/dev/null 2>&1
    echo "$1" | sudo tee $SL/vms/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/vms/cpuset.mems >/dev/null; fi; }
layout() { case $1 in UNPIN) pin $ALL 0-1 ;; PIN-N0) pin $N0 0 ;; esac; sleep 3
  local want=$([ $1 = UNPIN ] && echo $ALL || echo $N0) got=$(cat $SL/cpuset.cpus.effective) rc=$(awk '/Cpus_allowed_list/{print $2}' /proc/$(pgrep -nx rlp-runner)/status)
  local api=$(awk '/Cpus_allowed_list/{print $2}' /proc/$(pgrep -nx rlp-api)/status)
  [ "$got" = "$want" ] && [ "$rc" = "$want" ] || { say "LAYOUT MISMATCH $1 slice=$got runner=$rc want=$want"; return 1; }
  say "layout $1: slice=$got mems=$(cat $SL/cpuset.mems.effective) runner=$rc api=$api"; }
gate() { local w; for w in $(seq 1 60); do sudo /usr/local/bin/bench-preflight $1 >/dev/null && return 0; sleep 10; done
  say "PREFLIGHT FAIL $1: $(grep FAIL $1/preflight.txt | tr '\n' ' ')"; return 1; }
envc() { cd $BD && export PATH=$HOME/.local/bin:/usr/local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 && set -a && . ./.env && set +a && ulimit -n 1048576; }
fleet() { ( envc; export RLP_HTTP_MAX_CONNECTIONS=1024 RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0
    timeout 420 uv run python scripts/rlp_light_create_fleet.py --target $T --count $1 --workers $1 \
      --image dtgraviet/vera-agent-benchmark:v3 --cpu 0.025 --memory 0.0625 --disk 1.0 --probe 'echo ready' --output $2 ) > $2.log 2>&1; }
mpf() { ( envc; export RLP_HTTP_MAX_CONNECTIONS=1024 RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0
    timeout 600 uv run python mpfleet.py --target $T --procs $1 --count 1000 --output $2 ) > $2.log 2>&1; }
summ() { python3 - $1 <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
sb=[r for r in rows if r.get("type")=="sandbox"]; ok=[r for r in sb if r.get("status")=="ok"]
q=lambda a,x: sorted(a)[min(len(a)-1,int(x*len(a)))] if a else float("nan")
s=next((r for r in rows if r.get("type")=="summary"),{})
c=[r["create_s"] for r in ok]; p=[r.get("post_s",0) for r in ok]; w=[r.get("wait_s",0) for r in ok]; pr=[r.get("probe_s",0) for r in ok]
print(f"ok={len(ok)}/{len(sb)} wall={s.get('ready_wall_s',float('nan')):.2f} p50={q(c,.5):.2f} p95={q(c,.95):.2f} max={max(c) if c else 0:.2f} accept_p50={q(p,.5):.2f} accept_p95={q(p,.95):.2f} wait_p50={q(w,.5):.2f} probe_p50={q(pr,.5)*1000:.0f}ms")
PY
}
jcount() { local J="sudo journalctl -u rlp-runner --no-pager -o cat --since @$1 --until @$(( $2 + 5 ))"; echo "socktmo=$($J | grep -c 'not accepting') cordons=$($J | grep -c 'self-cordon entered')"; }
trap 'rc=$?; pin $ALL 0-1; say "SCRIPT EXIT rc=$rc (rlp.slice unpinned)"' EXIT
say "suite KT=$KT phases=$PHASES kernel=$(uname -r) page=$(getconf PAGESIZE) runner=$(sha256sum /usr/local/bin/rlp-runner | cut -c1-12)"

phaseA() { # 1k startup, single-process client (published method), UNPIN / PIN-N0 / UNPIN
  for arm in UNPIN-1 PIN-N0 UNPIN-2; do local lay=${arm%-[12]}; local d=$OUT/A/$arm; mkdir -p $d
    clean; layout $lay || return 1; fleet 10 $d/warm.jsonl
    for r in 1 2 3; do clean; gate $d/pf$r || return 1
      local t0=$(date +%s); fleet 1000 $d/rep$r.jsonl; local t1=$(date +%s)
      say "A $arm rep$r $(summ $d/rep$r.jsonl) $(jcount $t0 $t1)"; done; done; }
phaseB() { # client split: 1/4/8/16 procs on UNPIN, 16 procs on PIN-N0
  for spec in UNPIN:1 UNPIN:4 UNPIN:8 UNPIN:16 PIN-N0:16; do local lay=${spec%:*} p=${spec#*:}; local d=$OUT/B/$lay-p$p; mkdir -p $d
    clean; layout $lay || return 1
    for r in 1 2 3; do clean; gate $d/pf$r || return 1
      local t0=$(date +%s); mpf $p $d/rep$r.jsonl; local t1=$(date +%s)
      say "B $lay procs=$p rep$r $(summ $d/rep$r.jsonl) $(jcount $t0 $t1)"; done; done; }
phaseC() { # published dense ladder: agent n=45 seed 42 -E 8 hold-then-exec, cpu 0.025/max1, mem 0.0625/max4, disk 16 MiB, pool 512
  local LEVELS=${LEVELS:-"44 88 176 352 528 704 880 1056 1408 1760 2000"}
  for lay in ${C_ARMS:-UNPIN PIN-N0}; do local d=$OUT/C; mkdir -p $d
    clean; layout $lay || return 1; gate $d/pf-$lay || return 1
    local t0=$(date +%s)
    ( envc; export RLP_HTTP_MAX_CONNECTIONS=512 RLP_HOLD_CREATE_BATCH=512
      uv run main.py --benchmark agent --runner rlp --target $T --snapshot dtgraviet/vera-agent-benchmark:v3 \
        --levels $LEVELS --n 45 --seed 42 -E 8 --hold-then-exec --rlp-cpu 0.025 --rlp-cpu-max 1 \
        --rlp-memory 0.0625 --rlp-memory-max 4 --rlp-disk 0.015625 --output $d/$lay.jsonl ) > $d/$lay.log 2>&1
    local rc=$? t1=$(date +%s)
    say "C $lay exit=$rc $(( (t1-t0)/60 )) min $(jcount $t0 $t1)"
    python3 - $d/$lay.jsonl <<'PY' | while read l; do say "  C $l"; done
import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r.get("type")=="summary":
        print(f"c={r['concurrency']} runs={r['runs']} fail={r['failures']} chk={r['checksum_ok']} tput={r['throughput_per_sec']}/s p50_dur={r['p50_duration_ms']/1000:.2f}s p99={r['p99_ms']/1000:.1f}s create_wall={r.get('create_wall_s')}s")
PY
  done; }
for ph in $PHASES; do say "=== phase $ph"; phase$ph || say "phase $ph FAILED"; done
clean; say "DONE -> $OUT"
