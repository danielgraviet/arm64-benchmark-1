#!/bin/bash
# 4-arm startup test on Vera: Firecracker build (stock vs NVIDIA SMT fork) x guest shape (cap 1 vs 2 vCPU).
# Same runner binary in all arms; arm settings via a SECOND EnvironmentFile (overrides runner.env/api.env).
set -u
BD=/home/daytona/arm64-benchmark-1; REPS=${REPS:-3}; API=http://127.0.0.1:8088
OUT=/mnt/data/bench/fc-arms-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(sudo cat /etc/rlp/bench-api-key)
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
trap 'rc=$?; say "SCRIPT EXIT rc=$rc"' EXIT
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
renv() { sudo cat /proc/$(pgrep -nx $1)/environ 2>/dev/null | tr '\0' '\n' | grep -oP "^$2=\K.*"; }
POOL_WANT=$(sudo grep -oP '^RLP_NETNS_POOL=\K[0-9]+' /etc/rlp/runner.env)
clean() { local i; for i in $(seq 1 60); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id; done
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done
  say "WARN killing $(pgrep -c firecracker) orphans"; sudo pkill -x firecracker; sleep 5; sudo rm -rf /run/fc/* 2>/dev/null
  PG "update vms set status='deleted' where status not in ('deleted','failed','lost')" >/dev/null; }
wait_ready() { local n s; for i in $(seq 1 240); do n=$(sudo ip netns list | wc -l); s=$(PG "select status from runners limit 1")
    curl -fsS -m2 $API/health >/dev/null 2>&1 && [ "$s" = online ] && [ "$n" -ge $((POOL_WANT*95/100)) ] && { sleep 10; return 0; }; sleep 5; done
  say "WARN not ready: runner=$s pool=$n/$POOL_WANT"; return 1; }
fleet() { # $1 count  $2 outfile
  ( cd $BD && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 RLP_HTTP_MAX_CONNECTIONS=1024 \
      RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0 && set -a && . ./.env && set +a && ulimit -n 1048576 && \
    timeout 420 uv run python scripts/rlp_light_create_fleet.py --target vera --count $1 --workers $1 \
      --image dtgraviet/vera-agent-benchmark:v3 --cpu 0.025 --memory 0.0625 --disk 1.0 --probe 'echo ready' --output $2 ) > $2.log 2>&1; }
crashes() { local n=0 t=0; for f in /run/fc/*/serial.log; do [ -f "$f" ] || continue; t=$((t+1)); sudo grep -qE 'Internal error: Oops|recursive fault|Kernel panic' "$f" && n=$((n+1)); done; echo "guest_crashes=$n/$t"; }
summ() { grep -m1 '"type": *"summary"' $1 | grep -oE '"(ok|failed|ready_wall_s|create_p50_s|create_p95_s)": *[0-9.]+' | tr '\n' ' '; }
run_arm() { # $1 name $2 fc_bin $3 smt $4 cap
  local name=$1 fcbin=$2 smt=$3 cap=$4 arm=$OUT/$1; mkdir -p $arm
  printf 'RLP_FC_BIN=%s\nRLP_FC_SMT=%s\nRLP_FC_SOCK_WAIT_MS=30000\n' $fcbin $smt | sudo tee /etc/rlp/arm-runner.env >/dev/null
  printf 'RLP_BURST_MAX_CPU=%s\n' $cap | sudo tee /etc/rlp/arm-api.env >/dev/null
  printf '[Service]\nEnvironmentFile=/etc/rlp/arm-runner.env\n' | sudo tee /etc/systemd/system/rlp-runner.service.d/zz-arm.conf >/dev/null
  printf '[Service]\nEnvironmentFile=/etc/rlp/arm-api.env\n' | sudo tee /etc/systemd/system/rlp-api.service.d/zz-arm.conf >/dev/null
  clean; sudo systemctl daemon-reload; sudo systemctl restart rlp-api rlp-runner; sleep 5
  local a=$(renv rlp-runner RLP_FC_BIN) b=$(renv rlp-runner RLP_FC_SMT) c=$(renv rlp-api RLP_BURST_MAX_CPU) d=$(renv rlp-runner RLP_FC_SOCK_WAIT_MS)
  [ "$a" = "$fcbin" ] && [ "$b" = "$smt" ] && [ "$c" = "$cap" ] && [ "$d" = 30000 ] || { say "FATAL arm $name not applied: fc=$a smt=$b cap=$c sock=$d"; return 1; }
  wait_ready || return 1
  say "ARM $name: fc=$($fcbin --version | head -1) smt=$b cap=$c sock=$d preempt=$(sudo cat /sys/kernel/debug/sched/preempt | grep -oP '\(\K[a-z]+') pool=$(sudo ip netns list | wc -l)"
  # warmup: builds this arm's snapshot template (key includes FC version + shape)
  for w in 1 2 3; do clean; fleet 10 $arm/warm$w.jsonl; say "  warm$w: $(summ $arm/warm$w.jsonl) $(crashes)"; done
  sleep 45
  # guest shape actually delivered
  local vc=$(PG "select string_agg(distinct vcpus||'/'||vcpus_max, ',') from vms where created_at > now() - interval '3 min'")
  say "  guest vcpus/vcpus_max: $vc"
  for r in $(seq 1 $REPS); do
    clean; sleep 2; local t0=$(date -u +%s)
    fleet 1000 $arm/rep$r.jsonl
    local cr=$(crashes)
    local t1=$(date -u +%s)
    sudo journalctl -u rlp-runner --no-pager -o cat --since "@$t0" --until "@$((t1+5))" > $arm/rep$r.journal 2>/dev/null || true
    local st=$(grep -c 'fc.sock not accepting' $arm/rep$r.journal || true) cord=$(grep -c 'self-cordon entered' $arm/rep$r.journal || true)
    local tw=$(python3 - $arm/rep$r.journal <<'PY'
import re,sys
v=sorted(int(m.group(1)) for l in open(sys.argv[1],errors="replace") if (m:=re.search(r'toolbox_wait_ms=(\d+)',l)))
print(f"tw_p50={v[len(v)//2] if v else '?'} tw_p99={v[int(.99*len(v))] if v else '?'} tw_max={max(v) if v else '?'}")
PY
)
    say "  $name rep$r $(summ $arm/rep$r.jsonl) socktmo=$st cordons=$cord $tw $cr"
  done
}
FORK=/usr/local/bin/firecracker-rlpsmt2; STOCK=/usr/local/bin/firecracker
for a in ${ARMS:-A B C D}; do case $a in
  A) run_arm A-stock-cap1 $STOCK 0 1 ;;  B) run_arm B-fork-cap1 $FORK 1 1 ;;
  C) run_arm C-stock-cap2 $STOCK 0 2 ;;  D) run_arm D-fork-cap2 $FORK 1 2 ;; esac; done
# restore the bench defaults
sudo rm -f /etc/systemd/system/rlp-runner.service.d/zz-arm.conf /etc/systemd/system/rlp-api.service.d/zz-arm.conf /etc/rlp/arm-runner.env /etc/rlp/arm-api.env
sudo systemctl daemon-reload; sudo systemctl restart rlp-api rlp-runner; clean
say "DONE -> $OUT (arm overrides removed)"
