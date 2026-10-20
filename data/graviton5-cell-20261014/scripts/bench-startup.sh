#!/bin/bash
# bench-startup.sh N [REPS] — create-ready burst with the HQ Sep 8 client settings, no platform tuning.
#   client: pool 1024 (4096 for N>1000), polling 0.25 s x1.5 -> 2.0 s, disk 1 GiB, cpu 0.025, mem 64 MiB, probe 'echo ready'
set -u
N=${1:?count}; REPS=${2:-3}; TARGET=${TARGET:-graviton5}
cd ~/arm64-benchmark-1; export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1
set -a; . ./.env; set +a
POOL=$([ $N -le 1000 ] && echo 1024 || echo 4096)
export RLP_HTTP_MAX_CONNECTIONS=$POOL RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0
ulimit -n 1048576
RUN=/mnt/data/bench/startup-$TARGET-$N-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $RUN; sudo chown $(id -u):$(id -g) $RUN
K=$(sudo cat /etc/rlp/bench-api-key)
clean() { for i in $(seq 1 240); do
    for id in $(sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "select id from vms where status='running'"); do
      curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" http://127.0.0.1:8088/vms/$id; done
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done; echo "WARN not clean"; }
for r in $(seq 1 $REPS); do
  clean; sleep 2
  mkdir -p $RUN/rep$r; sudo /usr/local/bin/bench-preflight $RUN/rep$r >/dev/null || { echo "PREFLIGHT FAIL rep$r:"; grep FAIL $RUN/rep$r/preflight.txt; exit 1; }
  sudo chown -R $(id -u):$(id -g) $RUN
  uv run python scripts/rlp_light_create_fleet.py --target $TARGET --count $N --workers $N \
     --image dtgraviet/vera-agent-benchmark:v3 --cpu 0.025 --memory 0.0625 --disk 1.0 --probe 'echo ready' \
     --output $RUN/rep$r/create_ready_$N.jsonl > $RUN/rep$r/fleet.log 2>&1
  echo "rep$r rc=$? $(grep -m1 '"type": *"summary"' $RUN/rep$r/create_ready_$N.jsonl | grep -oE '"(ok|failed|ready_wall_s|create_p50_s|create_p95_s)": *[0-9.]+' | tr '\n' ' ')"
done
clean; echo "RUN DIR $RUN"
