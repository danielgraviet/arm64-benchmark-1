#!/bin/bash
# power-ladder.sh - jobs per watt. Idle power baseline, then the published dense agent ladder with every power domain sampled.
#   HOSTP=vera|phoenix|epyc9575 [LEVELS="44 176 352 704 2000"] [IDLE_S=180] [IDLE_ONLY=1] bash power-ladder.sh
#   IDLE_ONLY=1 records just the idle baseline (Turin: its 2026-10-15 ladder already sampled RAPL package power).
# Recipe = the throughput ladder of every report (agent, n=45, seed 42, -E 8, hold-then-exec, cpu .025/max 1, mem .0625/max 4,
# disk 16 MiB, create batch 512, http pool 512), whole box unpinned, fixes ON, exec/read timeout 1,800 s (needed at 2,000 on the 9575F).
set -u
source "$(dirname "$0")/common.sh"
LEVELS=${LEVELS:-"44 176 352 704 2000"}; IDLE_S=${IDLE_S:-180}
exec 9>/tmp/power-mem.lock; flock -n 9 || { echo "another power/mem run holds the lock"; exit 1; }
OUT=/mnt/data/bench/power-$HOSTP-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
say "power-ladder host=$HOSTP target=$T levels='$LEVELS' — waiting for 3 quiet minutes"; wait_idle
record_state; say "state: $(head -2 $OUT/host-state.txt | tr '\n' ' ')"
[ "$(cat $SL/cpuset.cpus.effective)" = "$ALL" ] || { say "ABORT: rlp.slice is pinned ($(cat $SL/cpuset.cpus.effective)), expected $ALL"; exit 1; }
clean; gate $OUT/pf-idle || exit 1
say "idle baseline ${IDLE_S}s"; sp=$(sampler $OUT/idle.samp); sleep $IDLE_S; stopsamp $sp $OUT/idle.samp
[ "${IDLE_ONLY:-0}" = 1 ] && { say "IDLE_ONLY done -> $OUT/idle.samp"; exit 0; }
sp=$(sampler $OUT/ladder.samp $OUT/ladder.jsonl); t0=$(date +%s)
( envc; export RLP_HTTP_MAX_CONNECTIONS=512 RLP_HOLD_CREATE_BATCH=512 RLP_HTTP_READ_TIMEOUT_S=1800
  $PY main.py --benchmark agent --runner rlp --target $T --snapshot dtgraviet/vera-agent-benchmark:v3 --levels $LEVELS \
    --n 45 --seed 42 -E 8 --hold-then-exec --exec-timeout 1800 --rlp-cpu 0.025 --rlp-cpu-max 1 --rlp-memory 0.0625 --rlp-memory-max 4 \
    --rlp-disk 0.015625 --output $OUT/ladder.jsonl ) > $OUT/ladder.log 2>&1
rc=$?; stopsamp $sp $OUT/ladder.samp; say "ladder exit=$rc $(( ($(date +%s)-t0)/60 )) min"
clean
python3 $HERE/power-report.py $OUT/idle.samp $OUT/ladder.samp $OUT/ladder.jsonl | tee $OUT/report.md
say "DONE -> $OUT"
