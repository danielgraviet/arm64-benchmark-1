#!/bin/bash
# Busy-core clock at light load: run a small agent level and sample the frequency of the cores
# that are actually running work (top-N by current frequency), so it is comparable to the
# all-core packed figure rather than averaged with idle cores.
set -u
BD=/home/ubuntu/arm64-benchmark-1
cd $BD; export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1
set -a; . ./.env; set +a; ulimit -n 1048576
( timeout 420 uv run main.py --benchmark agent --runner rlp --target phoenix-e6 \
    --snapshot dtgraviet/vera-agent-benchmark:v3 --levels 44 --n 6 --seed 42 -E 4 --hold-then-exec \
    --rlp-cpu 0.025 --rlp-cpu-max 1 --rlp-memory 0.0625 --rlp-memory-max 4 --rlp-disk 0.015625 \
    --output /tmp/clockprobe.jsonl ) > /tmp/clockprobe.log 2>&1 &
BG=$!
sleep 25
python3 - <<'PY'
import glob,time,statistics as st
def freqs():
    out=[]
    for f in glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq"):
        try: out.append(int(open(f).read())/1e6)
        except Exception: pass
    return sorted(out, reverse=True)
tops44=[]; tops8=[]; alls=[]
for _ in range(12):
    f=freqs()
    if not f: break
    tops44.append(st.mean(f[:44])); tops8.append(st.mean(f[:8])); alls.append(st.mean(f))
    time.sleep(2)
if tops44:
    print(f"light load (44 agent jobs): busiest-8 cores {st.mean(tops8):.3f} GHz | busiest-44 {st.mean(tops44):.3f} GHz | all-384 mean {st.mean(alls):.3f} GHz")
PY
wait $BG 2>/dev/null
grep -o '"throughput_per_sec": [0-9.]*\|"p50_duration_ms": [0-9.]*' /tmp/clockprobe.jsonl 2>/dev/null | tail -2
