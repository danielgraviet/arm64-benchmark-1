#!/bin/bash
# Phoenix E6 (EPYC 9J45 Turin, 2x96c) — startup baseline, pinned to one socket vs the whole box.
# Same shape as the HQ Vera pin-ab: 1,000 create-ready, warm snapshot clones, probe 'echo ready',
# cpu=0.025 mem=0.0625 GiB disk=1 GiB, single-process client (Vera-comparable) + one 16-process
# mpfleet rep per arm (the methodology's client for bursts >= 500).
set -u
BD=/home/ubuntu/arm64-benchmark-1; API=http://127.0.0.1:8088
OUT=/mnt/data/bench/pin-ab-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(sudo cat /etc/rlp/bench-api-key)
SL=/sys/fs/cgroup/rlp.slice
ALL=0-383; S0=0-95,192-287
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
clean() { local i; for i in $(seq 1 60); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id; done
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done
  say "WARN killing $(pgrep -c firecracker) orphans"; sudo pkill -x firecracker; sleep 5; sudo rm -rf /run/fc/* 2>/dev/null
  PG "update vms set status='deleted' where status not in ('deleted','failed','lost')" >/dev/null; }
fleet() { ( cd $BD && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 RLP_HTTP_MAX_CONNECTIONS=1024 \
      RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0 && set -a && . ./.env && set +a && ulimit -n 1048576 && \
    timeout 420 uv run python scripts/rlp_light_create_fleet.py --target phoenix-e6 --count $1 --workers $1 \
      --image dtgraviet/vera-agent-benchmark:v3 --cpu 0.025 --memory 0.0625 --disk 1.0 --probe 'echo ready' --output $2 ) > $2.log 2>&1; }
mpf() { ( cd $BD && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 && set -a && . ./.env && set +a && ulimit -n 1048576 && \
    timeout 420 uv run python mpfleet.py --target phoenix-e6 --count $1 --procs 16 --output $2 ) > $2.log 2>&1; }
summ() { grep -m1 '"type": *"summary"' $1 2>/dev/null | grep -oE '"(ok|failed|ready_wall_s|create_p50_s|create_p95_s)": *[0-9.]+' | tr '\n' ' '; }
pct() { python3 - $1 <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
ok=sorted(r["create_s"] for r in rows if r.get("type")=="sandbox" and r.get("status")=="ok")
p=sorted(r.get("post_s",0) for r in rows if r.get("type")=="sandbox" and r.get("status")=="ok")
q=lambda a,x: a[min(len(a)-1,int(x*len(a)))]
print(f"p50={q(ok,.5):.2f} p95={q(ok,.95):.2f} max={ok[-1]:.2f} accept_p50={q(p,.5):.2f}" if ok else "no-ok")
PY
}
pin() { # $1 cpus $2 mems — applies to live tasks; new firecrackers inherit. No runner restart.
  grep -qw cpuset /sys/fs/cgroup/cgroup.subtree_control || echo +cpuset | sudo tee /sys/fs/cgroup/cgroup.subtree_control >/dev/null
  grep -qw cpuset $SL/cgroup.subtree_control || echo +cpuset | sudo tee $SL/cgroup.subtree_control >/dev/null
  echo "$1" | sudo tee $SL/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/cpuset.mems >/dev/null
  if [ -d $SL/vms ]; then grep -qw cpuset $SL/vms/cgroup.subtree_control || echo +cpuset | sudo tee $SL/vms/cgroup.subtree_control >/dev/null 2>&1
    echo "$1" | sudo tee $SL/vms/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/vms/cpuset.mems >/dev/null; fi
  # control plane: one unit per set-property call; containers via docker update
  for u in rlp-api rlp-proxy; do sudo systemctl set-property --runtime $u AllowedCPUs="$1" >/dev/null 2>&1; sudo systemctl set-property --runtime $u AllowedMemoryNodes="$2" >/dev/null 2>&1; done
  for c in rlp-postgres rlp-nats; do sudo docker update --cpuset-cpus "$1" --cpuset-mems "$2" $c >/dev/null 2>&1; done; }
verify() { for p in rlp-runner rlp-api rlp-proxy; do
    printf '  %-11s cpus=%s mems=%s\n' $p "$(awk '/Cpus_allowed_list/{print $2}' /proc/$(pgrep -nx $p)/status 2>/dev/null)" "$(awk '/Mems_allowed_list/{print $2}' /proc/$(pgrep -nx $p)/status 2>/dev/null)"; done | tee -a $OUT/log
  printf '  %-11s cpus=%s mems=%s\n' postgres "$(sudo docker inspect rlp-postgres --format '{{.HostConfig.CpusetCpus}}')" "$(sudo docker inspect rlp-postgres --format '{{.HostConfig.CpusetMems}}')" | tee -a $OUT/log; }

run_arm() { # $1 name  $2 cpus  $3 mems  $4 reps
  local name=$1 reps=$4 arm=$OUT/$1; mkdir -p $arm
  clean; pin "$2" "$3"; sleep 5
  say "ARM $name: rlp.slice=$(cat $SL/cpuset.cpus.effective) mems=$(cat $SL/cpuset.mems.effective) vms=$(cat $SL/vms/cpuset.cpus.effective 2>/dev/null)"
  verify
  clean; fleet 10 $arm/warm.jsonl; say "  warm10: $(summ $arm/warm.jsonl)"
  for r in $(seq 1 $reps); do
    clean; sleep 2
    local ok=0; for w in $(seq 1 30); do sudo /usr/local/bin/bench-preflight $arm/pf$r >/dev/null && { ok=1; break; }; sleep 10; done
    [ $ok = 1 ] || { say "  PREFLIGHT failing after 5m rep$r: $(grep FAIL $arm/pf$r/preflight.txt | tr '\n' ' ')"; return 1; }
    local t0=$(date -u +%s); fleet 1000 $arm/rep$r.jsonl; local t1=$(date -u +%s)
    sudo journalctl -u rlp-runner --no-pager -o cat --since "@$t0" --until "@$((t1+5))" > $arm/rep$r.journal 2>/dev/null || true
    say "  $name rep$r 1p $(summ $arm/rep$r.jsonl) $(pct $arm/rep$r.jsonl) socktmo=$(grep -c 'fc.sock not accepting' $arm/rep$r.journal) cordons=$(grep -c 'self-cordon entered' $arm/rep$r.journal)"
  done
  clean; sleep 2; sudo /usr/local/bin/bench-preflight $arm/pfmp >/dev/null
  mpf 1000 $arm/mp.jsonl; say "  $name 16p $(tail -3 $arm/mp.jsonl.log | tr '\n' ' ')"
}

say "=== phoenix-e6 startup A/B. host=$(hostname) build=$(cat /etc/rlp/BUILD | cut -c1-80)"
trap 'pin $ALL 0-1; say "pin restored"' EXIT
run_arm PIN-S0 $S0  0   3
run_arm UNPIN  $ALL 0-1 3
pin $ALL 0-1; clean
say "DONE -> $OUT (rlp.slice unpinned: $(cat $SL/cpuset.cpus.effective))"
