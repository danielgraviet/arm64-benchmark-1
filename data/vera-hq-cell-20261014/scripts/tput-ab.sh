#!/bin/bash
# Throughput ladder on HQ Vera: rlp.slice (runner + sandboxes) pinned to socket 0 vs unpinned (both sockets).
# Published dense recipe (scripts/host/run_dense2k_vera.sh): agent bench, n=45, seed 42, -E 8, hold-then-exec,
# cpu 0.025/max 1, mem 0.0625/max 4, disk 1/64 GiB, HTTP pool 512. Levels default 176 352 704.
# Runs main.py directly (no clock/governor changes, nothing written under daniel-focus-here/).
set -u
BD=/home/daytona/arm64-benchmark-1; API=http://127.0.0.1:8088; SL=/sys/fs/cgroup/rlp.slice
LEVELS=${LEVELS:-"176 352 704"}; ARMS=${ARMS:-"UNPIN PIN-S0"}
OUT=/mnt/data/bench/tput-ab-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(sudo cat /etc/rlp/bench-api-key)
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
clean() { local i; for i in $(seq 1 60); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id & done; wait
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done; say "WARN $(pgrep -c firecracker) firecrackers left"; }
pin() { # $1 cpus $2 mems
  grep -qw cpuset /sys/fs/cgroup/cgroup.subtree_control || echo +cpuset | sudo tee /sys/fs/cgroup/cgroup.subtree_control >/dev/null
  grep -qw cpuset $SL/cgroup.subtree_control || echo +cpuset | sudo tee $SL/cgroup.subtree_control >/dev/null
  echo "$1" | sudo tee $SL/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/cpuset.mems >/dev/null
  if [ -d $SL/vms ]; then grep -qw cpuset $SL/vms/cgroup.subtree_control || echo +cpuset | sudo tee $SL/vms/cgroup.subtree_control >/dev/null 2>&1
    echo "$1" | sudo tee $SL/vms/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/vms/cpuset.mems >/dev/null; fi; }
ALL=0-351; S0=0-87,176-263
trap 'rc=$?; pin $ALL 0-1; say "SCRIPT EXIT rc=$rc (pin restored to $ALL)"' EXIT
run_arm() { # $1 name $2 cpus $3 mems
  local name=$1; clean; pin "$2" "$3"; sleep 5
  local ok=0; for w in $(seq 1 30); do sudo /usr/local/bin/bench-preflight $OUT/pf-$name >/dev/null && { ok=1; break; }; sleep 10; done
  [ $ok = 1 ] || { say "PREFLIGHT failing for $name: $(grep FAIL $OUT/pf-$name/preflight.txt | tr '\n' ' ')"; return 1; }
  say "ARM $name: rlp.slice cpus=$(cat $SL/cpuset.cpus.effective) mems=$(cat $SL/cpuset.mems.effective) vms=$(cat $SL/vms/cpuset.cpus.effective 2>/dev/null) runner=$(awk '/Cpus_allowed_list/{print $2}' /proc/$(pgrep -nx rlp-runner)/status) levels=$LEVELS"
  ( cd $BD && export PATH=$HOME/.local/bin:/usr/local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 && set -a && . ./.env && set +a && \
    export RLP_API_URL=$API RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox VERA_RLP_API_URL=$API \
           VERA_RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox VERA_RLP_TARGET=vera RLP_HTTP_MAX_CONNECTIONS=512 RLP_HOLD_CREATE_BATCH=512 && \
    ulimit -n 1048576 && \
    uv run main.py --benchmark agent --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark:v3 \
      --levels $LEVELS --n 45 --seed 42 -E 8 --hold-then-exec --rlp-cpu 0.025 --rlp-cpu-max 1 \
      --rlp-memory 0.0625 --rlp-memory-max 4 --rlp-disk 0.015625 --output $OUT/$name.jsonl ) > $OUT/$name.log 2>&1
  say "  $name exit=$?"
  python3 - $OUT/$name.jsonl <<'PY' | while read l; do say "  $l"; done
import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r.get("type")=="summary":
        print(f"c={r['concurrency']} runs={r['runs']} failures={r['failures']} tput={r['throughput_per_sec']}/s p50={r['p50_ms']/1000:.1f}s p99={r['p99_ms']/1000:.1f}s")
PY
}
for a in $ARMS; do case $a in UNPIN) run_arm UNPIN $ALL 0-1 ;; PIN-S0) run_arm PIN-S0 $S0 0 ;; esac; done
clean; say "DONE -> $OUT"
