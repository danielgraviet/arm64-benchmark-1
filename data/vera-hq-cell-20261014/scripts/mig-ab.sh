#!/bin/bash
# #3213 repro: 2-vCPU snapshot clones on Vera, stock Firecracker, RLP_MIGRATABLE=1 (KVM dirty tracking re-armed on load)
# vs RLP_MIGRATABLE=0. Arms interleaved M1 M0 M1 (ARMS env). Per arm: 3 warmups of 10 (template build), then BATCHES x
# BATCH creates with --keep; guest oopses counted from serial logs BEFORE cleanup. Arm settings via a second
# EnvironmentFile drop-in (EnvironmentFile beats Environment=); verified from /proc/<pid>/environ.
set -u
BD=/home/daytona/arm64-benchmark-1; API=http://127.0.0.1:8088
BATCHES=${BATCHES:-5}; BATCH=${BATCH:-100}; ARMS=${ARMS:-"M1 M0 M1b"}
OUT=/mnt/data/bench/mig-ab-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(sudo cat /etc/rlp/bench-api-key)
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
trap 'rc=$?; say "SCRIPT EXIT rc=$rc"' EXIT
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
renv() { sudo cat /proc/$(pgrep -nx $1)/environ 2>/dev/null | tr '\0' '\n' | grep -oP "^$2=\K.*"; }
POOL_WANT=$(sudo grep -oP '^RLP_NETNS_POOL=\K[0-9]+' /etc/rlp/runner.env)
clean() { local i; for i in $(seq 1 60); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id & done; wait
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done
  say "WARN killing $(pgrep -c firecracker) orphans"; sudo pkill -x firecracker; sleep 5; sudo rm -rf /run/fc/* 2>/dev/null
  PG "update vms set status='deleted' where status not in ('deleted','failed','lost')" >/dev/null; }
wait_ready() { local n s; for i in $(seq 1 240); do n=$(sudo ip netns list | wc -l); s=$(PG "select status from runners limit 1")
    curl -fsS -m2 $API/health >/dev/null 2>&1 && [ "$s" = online ] && [ "$n" -ge $((POOL_WANT*95/100)) ] && { sleep 10; return 0; }; sleep 5; done
  say "WARN not ready: runner=$s pool=$n/$POOL_WANT"; return 1; }
fleet() { # $1 count  $2 outfile
  ( cd $BD && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 RLP_HTTP_MAX_CONNECTIONS=1024 \
      RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0 && set -a && . ./.env && set +a && ulimit -n 1048576 && \
    timeout 150 uv run python scripts/rlp_light_create_fleet.py --target vera --count $1 --workers $1 --keep \
      --image dtgraviet/vera-agent-benchmark:v3 --cpu 0.025 --memory 0.0625 --disk 1.0 --probe 'echo ready' \
      --probe-timeout 30 --output $2 ) > $2.log 2>&1; }
oops() { # $1 prefix. Count guests whose serial log shows a kernel oops (as root: /run/fc is 0750 root); save one trace.
  local r; r=$(sudo bash -c 't=0; n=0; first=; for f in /run/fc/*/serial.log; do [ -f "$f" ] || continue; t=$((t+1));
      if grep -qE "Internal error: Oops|Unable to handle kernel|recursive fault|Kernel panic" "$f"; then n=$((n+1)); [ -z "$first" ] && first=$f; fi; done
    [ -n "$first" ] && grep -B2 -A30 -m1 -E "Internal error: Oops|Unable to handle kernel" "$first" > '"$1"'.oops; echo "oops=$n/$t"')
  echo "$r"; }
summ() { python3 - $1 $2 <<'PY'
import json,sys,collections
ok=fail=0; err=collections.Counter()
for l in open(sys.argv[1]):
    try: r=json.loads(l)
    except: continue
    if r.get("type")!="sandbox": continue
    if r.get("status")=="ok": ok+=1
    else: fail+=1; err[(r.get("error") or "?")[:60]]+=1
missing=int(sys.argv[2])-ok-fail
print(f"ok={ok} failed={fail} missing={missing} " + "; ".join(f"{c}x {e}" for e,c in err.most_common(3)))
PY
}
run_arm() { # $1 name  $2 migratable
  local name=$1 mig=$2 arm=$OUT/$1; mkdir -p $arm
  printf 'RLP_MIGRATABLE=%s\nRLP_FC_SOCK_WAIT_MS=30000\n' $mig | sudo tee /etc/rlp/arm-runner.env >/dev/null
  printf 'RLP_BURST_MAX_CPU=2\n' | sudo tee /etc/rlp/arm-api.env >/dev/null
  printf '[Service]\nEnvironmentFile=/etc/rlp/arm-runner.env\n' | sudo tee /etc/systemd/system/rlp-runner.service.d/zz-arm.conf >/dev/null
  printf '[Service]\nEnvironmentFile=/etc/rlp/arm-api.env\n' | sudo tee /etc/systemd/system/rlp-api.service.d/zz-arm.conf >/dev/null
  clean; sudo systemctl daemon-reload; sudo systemctl restart rlp-api; sudo systemctl restart rlp-runner; sleep 5
  local a=$(renv rlp-runner RLP_MIGRATABLE) c=$(renv rlp-api RLP_BURST_MAX_CPU) fb=$(renv rlp-runner RLP_FC_BIN)
  [ "$a" = "$mig" ] && [ "$c" = 2 ] || { say "FATAL arm $name not applied: migratable=$a cap=$c"; return 1; }
  wait_ready || return 1
  say "ARM $name: RLP_MIGRATABLE=$a cap=$c fc_bin=${fb:-default} fc=$(${fb:-/usr/local/bin/firecracker} --version | head -1)"
  for w in 1 2 3; do clean; fleet 10 $arm/warm$w.jsonl; say "  warm$w: $(summ $arm/warm$w.jsonl 10) $(oops $arm/warm$w)"; done
  local vc=$(PG "select string_agg(distinct vcpus::text, ',') from vms where created_at > now() - interval '5 min'")
  say "  guest vcpus: $vc"
  for b in $(seq 1 $BATCHES); do
    clean; sleep 2; fleet $BATCH $arm/b$b.jsonl; sleep 5
    say "  $name b$b $(summ $arm/b$b.jsonl $BATCH) $(oops $arm/b$b)"
  done
  clean
}
for a in $ARMS; do case $a in M1|M1b) run_arm $a 1 ;; M0|M0b) run_arm $a 0 ;; esac; done
sudo rm -f /etc/systemd/system/rlp-runner.service.d/zz-arm.conf /etc/systemd/system/rlp-api.service.d/zz-arm.conf /etc/rlp/arm-runner.env /etc/rlp/arm-api.env
sudo systemctl daemon-reload; sudo systemctl restart rlp-api; sudo systemctl restart rlp-runner; clean
say "DONE -> $OUT (arm overrides removed)"
