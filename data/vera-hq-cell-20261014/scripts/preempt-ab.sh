#!/bin/bash
# A/B the host preemption model on Vera's guest-wake tail (toolbox_wait).
# Vera ships preempt=none (NVIDIA cmdline); the 9575F runs preempt=full and shows no tail.
# PREEMPT_DYNAMIC lets us switch at runtime, so this needs no reboot.
# The FC socket wait is pinned at 30000 ms in BOTH arms so that variable is out.
set -u
T=vera; BD=/home/daytona/arm64-benchmark-1; REPS=${1:-3}; API=http://127.0.0.1:8088
OUT=/mnt/data/bench/preempt-ab-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(sudo cat /etc/rlp/bench-api-key)
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
trap 'rc=$?; [ $rc -ne 0 ] && say "SCRIPT EXIT rc=$rc"' EXIT
PG() { sudo docker exec -i rlp-postgres psql -U rlp -d rlplatform -tAc "$1" 2>/dev/null \
    || sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
POOL_WANT=$(sudo grep -oP '^RLP_NETNS_POOL=\K[0-9]+' /etc/rlp/runner.env)
clean() { local i; for i in $(seq 1 60); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id; done
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done
  say "WARN killing $(pgrep -c firecracker) orphans"; sudo pkill -x firecracker; sleep 5; sudo rm -rf /run/fc/* 2>/dev/null
  PG "update vms set status='deleted' where status not in ('deleted','failed','lost')" >/dev/null; }
wait_pool() { local n; for i in $(seq 1 240); do n=$(sudo ip netns list | wc -l)
    [ "$(PG "select status from runners limit 1")" = online ] && [ "$n" -ge $((POOL_WANT*95/100)) ] && { sleep 10; return 0; }; sleep 5; done
  say "WARN pool $n/$POOL_WANT"; }
# pin the socket wait for both arms
sudo mkdir -p /etc/systemd/system/rlp-runner.service.d
printf '[Service]\nEnvironment=RLP_FC_SOCK_WAIT_MS=30000\n' | sudo tee /etc/systemd/system/rlp-runner.service.d/zz-fcsock.conf >/dev/null
sudo systemctl daemon-reload; sudo systemctl restart rlp-runner; sleep 5; wait_pool
run_arm() { local mode=$1 arm=$OUT/preempt-$1; mkdir -p $arm
  echo $mode | sudo tee /sys/kernel/debug/sched/preempt >/dev/null
  local eff=$(sudo cat /sys/kernel/debug/sched/preempt | grep -oP '\(\K[a-z]+')
  [ "$eff" = "$mode" ] || { say "FATAL preempt not applied: want=$mode got=$eff"; return 1; }
  say "ARM preempt=$mode (effective=$eff) fc_sock_wait=$(sudo cat /proc/$(pgrep -nx rlp-runner)/environ | tr '\0' '\n' | grep -oP 'RLP_FC_SOCK_WAIT_MS=\K.*') pool=$(sudo ip netns list | wc -l)"
  for r in $(seq 1 $REPS); do
    clean; sleep 2; local t0=$(date -u +%s)
    ( cd $BD && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 RLP_HTTP_MAX_CONNECTIONS=1024 \
        RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0 && set -a && . ./.env && set +a && ulimit -n 1048576 && \
      uv run python scripts/rlp_light_create_fleet.py --target $T --count 1000 --workers 1000 \
        --image dtgraviet/vera-agent-benchmark:v3 --cpu 0.025 --memory 0.0625 --disk 1.0 --probe 'echo ready' \
        --output $arm/rep$r.jsonl ) > $arm/rep$r.log 2>&1
    local t1=$(date -u +%s)
    sudo journalctl -u rlp-runner --no-pager -o cat --since "@$t0" --until "@$((t1+5))" > $arm/rep$r.journal 2>/dev/null || true
    local tw=$(python3 - "$arm/rep$r.journal" <<'PY'
import re,sys
v=[int(m.group(1)) for l in open(sys.argv[1],errors="replace") if (m:=re.search(r'toolbox_wait_ms=(\d+)',l))]
v.sort()
print(f"tw_p50={v[len(v)//2] if v else '?'} tw_p99={v[int(.99*len(v))] if v else '?'} tw_max={max(v) if v else '?'} over5s={sum(1 for x in v if x>5000)} over20s={sum(1 for x in v if x>20000)} n={len(v)}")
PY
)
    say "  $mode rep$r $(grep -m1 '"type": *"summary"' $arm/rep$r.jsonl | grep -oE '"(ok|failed|ready_wall_s|create_p50_s|create_p95_s)": *[0-9.]+' | tr '\n' ' ') $tw"
  done
  wait_pool
}
run_arm none
run_arm full
echo none | sudo tee /sys/kernel/debug/sched/preempt >/dev/null   # restore NVIDIA's shipped setting
sudo rm -f /etc/systemd/system/rlp-runner.service.d/zz-fcsock.conf; sudo systemctl daemon-reload; sudo systemctl restart rlp-runner
clean; say "DONE -> $OUT (preempt restored to $(sudo cat /sys/kernel/debug/sched/preempt | grep -oP '\(\K[a-z]+'), fc knob reverted)"
