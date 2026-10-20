# Host memory per sandbox WHILE the agent ladder runs (UNPIN, one level), sampled every 2 s.
set -u
L=${L:-704}
cd ~/arm64-benchmark-1 && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 && set -a && . ./.env && set +a && ulimit -n 1048576
export RLP_HTTP_MAX_CONNECTIONS=512 RLP_HOLD_CREATE_BATCH=512
OUT=/mnt/data/bench/memload-$(getconf PAGESIZE)-$(date -u +%H%M%S); mkdir -p $OUT
sudo bench-preflight $OUT/pf >/dev/null || grep FAIL $OUT/pf/preflight.txt
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null; sleep 3
base=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
( while :; do echo "$(date +%s) $(awk '/MemAvailable/{print $2}' /proc/meminfo) $(pgrep -c firecracker) $(sudo cat /sys/fs/cgroup/rlp.slice/vms/memory.current)"; sleep 2; done ) > $OUT/mem.txt & S=$!
uv run main.py --benchmark agent --runner rlp --target graviton5 --snapshot dtgraviet/vera-agent-benchmark:v3 --levels $L --n 45 --seed 42 -E 8 --hold-then-exec \
  --rlp-cpu 0.025 --rlp-cpu-max 1 --rlp-memory 0.0625 --rlp-memory-max 4 --rlp-disk 0.015625 --output $OUT/L.jsonl > $OUT/L.log 2>&1
kill $S
python3 - $OUT/mem.txt $base $L <<'PY'
import sys
rows=[list(map(int,l.split())) for l in open(sys.argv[1]) if len(l.split())==4]
base=int(sys.argv[2]); L=int(sys.argv[3])
pk=min(rows,key=lambda r:r[1]); used=(base-pk[1])/1024; cg=max(r[3] for r in rows)/2**20
print(f"page={__import__('os').sysconf('SC_PAGE_SIZE')} level={L} peak host used={used/1024:.1f} GiB -> {used/L:.0f} MiB/sandbox; peak rlp.slice/vms memory.current={cg/1024:.1f} GiB -> {cg/L:.0f} MiB/sandbox (fc at peak={pk[2]})")
PY
grep -h '"summary"' $OUT/L.jsonl | python3 -c "import sys,json;[print('tput',r['throughput_per_sec'],'fails',r['failures']) for r in map(json.loads,sys.stdin)]"
