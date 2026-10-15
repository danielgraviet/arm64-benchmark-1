# Idle host memory per sandbox: 500 sandboxes created + 'echo ready', kept; measure firecracker RSS and node MemUsed delta.
set -u
cd ~/arm64-benchmark-1 && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 && set -a && . ./.env && set +a && ulimit -n 1048576
OUT=/mnt/data/bench/memprobe-$(getconf PAGESIZE)-$(date -u +%H%M%S); mkdir -p $OUT
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null; sleep 3
u0=$(numastat -m | awk '/MemUsed/{print $4}')
RLP_HTTP_MAX_CONNECTIONS=1024 uv run python scripts/rlp_light_create_fleet.py --target graviton5 --count 500 --workers 500 \
  --image dtgraviet/vera-agent-benchmark:v3 --cpu 0.025 --memory 0.0625 --disk 1.0 --probe 'echo ready' --keep --output $OUT/fleet.jsonl > $OUT/fleet.log 2>&1
sleep 20
u1=$(numastat -m | awk '/MemUsed/{print $4}')
pids=$(pgrep -x firecracker)
python3 - $pids <<'PY'
import sys
v=[]
for p in sys.argv[1:]:
    try:
        for l in open(f"/proc/{p}/status"):
            if l.startswith("RssAnon"): v.append(int(l.split()[1]))
    except: pass
v.sort(); n=len(v)
print(f"firecrackers={n} RssAnon MiB: mean={sum(v)/n/1024:.1f} p50={v[n//2]/1024:.1f} max={v[-1]/1024:.1f} total={sum(v)/1048576:.1f} GiB")
PY
echo "node MemUsed delta: $(python3 -c "print(f'{($u1-$u0)/1024:.1f} GiB total, {($u1-$u0)/500:.1f} MiB per sandbox')")  page=$(getconf PAGESIZE)"
grep -m1 '"type": *"summary"' $OUT/fleet.jsonl | grep -oE '"(ok|failed)": *[0-9]+' | tr '\n' ' '; echo
