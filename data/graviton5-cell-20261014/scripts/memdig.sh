# Where does a clone's host memory go? 20 kept sandboxes; smaps of one FC + guest view.
set -u
cd ~/arm64-benchmark-1 && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 && set -a && . ./.env && set +a
OUT=/mnt/data/bench/memdig-$(getconf PAGESIZE)-$(date -u +%H%M%S); mkdir -p $OUT
uv run python scripts/rlp_light_create_fleet.py --target graviton5 --count 20 --workers 20 --image dtgraviet/vera-agent-benchmark:v3 \
  --cpu 0.025 --memory 0.0625 --disk 1.0 --probe 'echo ready' --keep --output $OUT/fleet.jsonl > $OUT/fleet.log 2>&1
sleep 15
K=$(sudo cat /etc/rlp/bench-api-key)
ID=$(python3 -c "import json;print([json.loads(l) for l in open('$OUT/fleet.jsonl') if '\"sandbox\"' in l][0]['sandbox_id'])")
PID=$(pgrep -f "firecracker.*" -a | grep -m1 "$ID" | awk '{print $1}')
[ -z "$PID" ] && PID=$(for p in $(pgrep -x firecracker); do sudo readlink /proc/$p/cwd | grep -q $ID && echo $p; done | head -1)
echo "vm=$ID fc_pid=$PID page=$(getconf PAGESIZE)"
echo "== FC smaps_rollup"; sudo grep -E "^(Rss|Pss|Shared_Clean|Shared_Dirty|Private_Clean|Private_Dirty|Anonymous|AnonHugePages)" /proc/$PID/smaps_rollup
echo "== top mappings by Rss (kB): rss anon private_dirty size name"
sudo awk '/^[0-9a-f]+-[0-9a-f]+ /{name=$6; split($1,a,"-"); size=(strtonum("0x"a[2])-strtonum("0x"a[1]))/1024} /^Rss:/{rss=$2} /^Anonymous:/{an=$2} /^Private_Dirty:/{pd=$2; if(rss>1000) printf "%8d %8d %8d %9d %s\n", rss, an, pd, size, name}' /proc/$PID/smaps | sort -rn | head -8
echo "== guest view"
curl -s -m 30 -X POST "http://127.0.0.1:9000/toolbox/$ID/process/execute" -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
  -d '{"command":"head -5 /proc/meminfo; grep -E \"^(AnonPages|Shmem|Slab|PageTables|KernelStack|Cached|Buffers)\" /proc/meminfo; getconf PAGESIZE; nproc"}' | python3 -c "import sys,json;print(json.load(sys.stdin).get('result'))"
echo "== template mem file"; sudo ls -la $(sudo readlink -f $(sudo readlink /proc/$PID/cwd)/mem 2>/dev/null) 2>/dev/null; sudo ls -la $(sudo readlink /proc/$PID/cwd)/ | head -20
