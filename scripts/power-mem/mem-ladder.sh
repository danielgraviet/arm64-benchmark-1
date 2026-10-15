#!/bin/bash
# mem-ladder.sh - memory-bandwidth workload: N concurrent 1-vCPU sandboxes each running a STREAM-style triad on 384 MiB (3 arrays x 2^24 doubles).
#   HOSTP=vera|phoenix|epyc9575|graviton5 [LEVELS="1 8 32 64 128 176 256 352"] [SECS=30] [REPS=2] bash mem-ladder.sh
# Levels above the host's hardware-thread count are skipped. Power + busy-core clock sampled throughout (no power on Graviton5).
set -u
source "$(dirname "$0")/common.sh"
LEVELS=${LEVELS:-"1 8 32 64 128 176 256 352"}; SECS=${SECS:-30}; REPS=${REPS:-2}; ELEMS=${ELEMS:-16777216}
exec 9>/tmp/power-mem.lock; flock -n 9 || { echo "another power/mem run holds the lock"; exit 1; }
OUT=/mnt/data/bench/mem-$HOSTP-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
cp $HERE/memtest.c $HERE/memfleet.py $OUT/
say "mem-ladder host=$HOSTP target=$T levels='$LEVELS' secs=$SECS reps=$REPS elems=$ELEMS — waiting for 3 quiet minutes"; wait_idle
record_state
[ "$(cat $SL/cpuset.cpus.effective)" = "$ALL" ] || { say "ABORT: rlp.slice is pinned ($(cat $SL/cpuset.cpus.effective)), expected $ALL"; exit 1; }
mf() { ( envc; MEMTEST_SRC=$HERE/memtest.c timeout $(( ${SECS%.*} + 900 )) $PY $HERE/memfleet.py --target $T --count $1 \
         --procs $(( $1 < 16 ? $1 : 16 )) --secs $2 --elems $ELEMS --output $3 ) > $3.log 2>&1; tail -1 $3.log; }
clean; say "warm (builds the gcc:14 template): $(mf 4 2 $OUT/warm.jsonl)"; clean
NP=$(nproc)
for c in $LEVELS; do [ $c -gt $NP ] && { say "skip c=$c > nproc $NP"; continue; }
  for r in $(seq 1 $REPS); do f=$OUT/c$c-r$r.jsonl
    clean; gate $OUT/pf-$c-$r || exit 1
    sp=$(sampler $f.samp); s=$(mf $c $SECS $f); stopsamp $sp $f.samp
    say "c=$c r$r $s"; done; done
clean
python3 $HERE/mem-report.py $OUT | tee $OUT/report.md
say "DONE -> $OUT"
