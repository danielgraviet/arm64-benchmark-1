# Per-core speed light vs packed on Graviton5: guest cgroup cycles/instructions + CPU time, published agent recipe.
set -u
cd ~/arm64-benchmark-1 && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 && set -a && . ./.env && set +a && ulimit -n 1048576
export RLP_HTTP_MAX_CONNECTIONS=512 RLP_HOLD_CREATE_BATCH=512
OUT=/mnt/data/bench/percore-$(getconf PAGESIZE)-$(date -u +%H%M%S); mkdir -p $OUT
us() { sudo awk '/usage_usec/{print $2}' /sys/fs/cgroup/rlp.slice/vms/cpu.stat; }
for L in ${LEVELS:-96 352}; do
  sudo bench-preflight $OUT/pf-$L >/dev/null || { echo "preflight fail $L"; grep FAIL $OUT/pf-$L/preflight.txt; }
  u0=$(us)
  sudo perf stat -a -e cycles,instructions -G rlp.slice/vms,rlp.slice/vms -x, -o $OUT/perf-$L.csv -- \
    sudo -u $USER env PATH=$PATH UV_NO_SYNC=1 HOME=$HOME bash -c "cd $PWD; set -a; . ./.env; set +a; export RLP_HTTP_MAX_CONNECTIONS=512 RLP_HOLD_CREATE_BATCH=512; ulimit -n 1048576; uv run main.py --benchmark agent --runner rlp --target graviton5 --snapshot dtgraviet/vera-agent-benchmark:v3 --levels $L --n 45 --seed 42 -E 8 --hold-then-exec --rlp-cpu 0.025 --rlp-cpu-max 1 --rlp-memory 0.0625 --rlp-memory-max 4 --rlp-disk 0.015625 --output $OUT/L$L.jsonl" > $OUT/L$L.log 2>&1
  u1=$(us)
  python3 - $OUT/perf-$L.csv $OUT/L$L.jsonl $u0 $u1 $L <<'PY'
import sys,json
cyc=ins=0
for l in open(sys.argv[1]):
    f=l.strip().split(",")
    if len(f)>3 and f[0].isdigit():
        if f[2].startswith("cycles"): cyc=int(f[0])
        if f[2].startswith("instructions"): ins=int(f[0])
s=[json.loads(l) for l in open(sys.argv[2]) if '"summary"' in l][-1]
cpu=(int(sys.argv[4])-int(sys.argv[3]))/1e6
print(f"c={sys.argv[5]:>4} jobs/s={s['throughput_per_sec']:6.2f} job_p50={s['p50_duration_ms']/1000:5.2f}s fails={s['failures']} guest_cpu={cpu:7.0f} core-s  core-s/job={cpu/s['runs']:5.2f}  GHz={cyc/cpu/1e9:4.2f}  IPC={ins/cyc:4.2f}")
PY
  sleep 20
done
