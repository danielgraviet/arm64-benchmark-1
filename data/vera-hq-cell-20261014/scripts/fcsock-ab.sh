#!/bin/bash
# A/B the Firecracker API-socket spawn wait. Same binary in both arms; only RLP_FC_SOCK_WAIT_MS differs.
# usage: fcsock-ab.sh <target> <bench_dir> [reps]
set -u
T=${1:?target}; BD=${2:?bench dir}; REPS=${3:-3}; API=http://127.0.0.1:8088
OUT=/mnt/data/bench/fcsock-ab-$T-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(sudo cat /etc/rlp/bench-api-key)
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
trap 'rc=$?; [ $rc -ne 0 ] && say "SCRIPT EXIT rc=$rc line=$LINENO"' EXIT
PG() { # the two cell layouts differ: host-net postgres on :5439 (vera) vs bridge container on its default socket (9575F)
  sudo docker exec -i rlp-postgres psql -U rlp -d rlplatform -tAc "$1" 2>/dev/null \
    || sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
renv() { sudo cat /proc/$(pgrep -nx rlp-runner)/environ 2>/dev/null | tr '\0' '\n' | grep -oP "^$1=\K.*"; }   # privileged read, not a shell redirect
POOL_WANT=$(sudo grep -oP '^RLP_NETNS_POOL=\K[0-9]+' /etc/rlp/runner.env 2>/dev/null || echo 0)
say "pool target from runner.env: ${POOL_WANT:-0}"
clean() { local i
  for i in $(seq 1 60); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id; done
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5
  done
  # orphans: a firecracker whose row the API no longer tracks never clears by DELETE
  say "WARN $(pgrep -c firecracker) firecracker left after 5m; killing orphans"
  sudo pkill -x firecracker; sleep 5; sudo rm -rf /run/fc/* 2>/dev/null
  PG "update vms set status='deleted' where status not in ('deleted','failed','lost')" >/dev/null; }
wait_ready() { local n s
  for i in $(seq 1 240); do n=$(sudo ip netns list | wc -l); s=$(PG "select status from runners limit 1")
    [ "$s" = online ] && [ "$POOL_WANT" -gt 0 ] && [ "$n" -ge $((POOL_WANT*95/100)) ] && { sleep 10; return 0; }
    sleep 5; done
  say "WARN not ready after 20m: runner=$s pool=$n/$POOL_WANT"; return 1; }
run_arm() { local ms=$1 arm=$OUT/arm-${1}ms; mkdir -p $arm
  sudo mkdir -p /etc/systemd/system/rlp-runner.service.d
  printf '[Service]\nEnvironment=RLP_FC_SOCK_WAIT_MS=%s\n' "$ms" | sudo tee /etc/systemd/system/rlp-runner.service.d/zz-fcsock.conf >/dev/null
  sudo systemctl daemon-reload; sudo systemctl restart rlp-runner || { say "FATAL restart failed"; return 1; }
  sleep 5
  local eff=$(renv RLP_FC_SOCK_WAIT_MS)
  [ "$eff" = "$ms" ] || { say "FATAL knob not applied: want=$ms got=${eff:-unset}"; return 1; }
  wait_ready || return 1
  say "ARM ${ms}ms: env=$eff sha=$(sha256sum /usr/local/bin/rlp-runner | cut -c1-12) pool=$(sudo ip netns list | wc -l)"
  for r in $(seq 1 $REPS); do
    clean; sleep 2
    local t0=$(date -u +%s)
    ( cd $BD && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 RLP_HTTP_MAX_CONNECTIONS=1024 \
        RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0 && set -a && . ./.env && set +a && ulimit -n 1048576 && \
      uv run python scripts/rlp_light_create_fleet.py --target $T --count 1000 --workers 1000 \
        --image dtgraviet/vera-agent-benchmark:v3 --cpu 0.025 --memory 0.0625 --disk 1.0 --probe 'echo ready' \
        --output $arm/rep$r.jsonl ) > $arm/rep$r.log 2>&1
    local t1=$(date -u +%s)
    sudo journalctl -u rlp-runner --no-pager -o cat --since "@$t0" --until "@$((t1+5))" > $arm/rep$r.journal 2>/dev/null || true
    local st=$(grep -c 'fc.sock not accepting' $arm/rep$r.journal || true)
    local cord=$(grep -c 'self-cordon entered' $arm/rep$r.journal || true)
    local summ=$(grep -m1 '"type": *"summary"' $arm/rep$r.jsonl | grep -oE '"(ok|failed|ready_wall_s|create_p50_s|create_p95_s)": *[0-9.]+' | tr '\n' ' ' || true)
    say "  ${ms}ms rep$r $summ socktimeouts=${st:-?} cordons=${cord:-?}"
  done
  wait_ready
}
clean; wait_ready || say "WARN starting with a cold pool"
run_arm 3000; run_arm 30000
sudo rm -f /etc/systemd/system/rlp-runner.service.d/zz-fcsock.conf; sudo systemctl daemon-reload; sudo systemctl restart rlp-runner
clean; say "DONE -> $OUT (knob reverted)"
