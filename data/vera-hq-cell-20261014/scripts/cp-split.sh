#!/bin/bash
# Event-audit A/B on HQ Vera: ON (fresh API) / OFF (fresh API) / ON (fresh API, 6 reps -> drift without restart).
# Only rlp-api restarts between arms; runner, netns pool and templates stay warm. Preflight gates every rep.
set -u
BD=/home/daytona/arm64-benchmark-1; API=http://127.0.0.1:8088
OUT=/mnt/data/bench/cp-split-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(sudo cat /etc/rlp/bench-api-key)
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
renv() { sudo cat /proc/$(pgrep -nx $1)/environ 2>/dev/null | tr '\0' '\n' | grep -oP "^$2=\K.*"; }
clean() { local i; for i in $(seq 1 60); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id; done
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done
  say "WARN killing $(pgrep -c firecracker) orphans"; sudo pkill -x firecracker; sleep 5; sudo rm -rf /run/fc/* 2>/dev/null
  PG "update vms set status='deleted' where status not in ('deleted','failed','lost')" >/dev/null; }
fleet() { ( cd $BD && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 RLP_HTTP_MAX_CONNECTIONS=1024 \
      RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0 && set -a && . ./.env && set +a && ulimit -n 1048576 && \
    timeout 420 taskset -c $CLIENT_CPUS numactl -m $CLIENT_MEMS uv run python scripts/rlp_light_create_fleet.py --target vera --count $1 --workers $1 \
      --image dtgraviet/vera-agent-benchmark:v3 --cpu 0.025 --memory 0.0625 --disk 1.0 --probe 'echo ready' --output $2 ) > $2.log 2>&1; }
summ() { grep -m1 '"type": *"summary"' $1 | grep -oE '"(ok|failed|ready_wall_s|create_p50_s|create_p95_s)": *[0-9.]+' | tr '\n' ' '; }
pct() { python3 - $1 <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
ok=sorted(r["create_s"] for r in rows if r.get("type")=="sandbox" and r.get("status")=="ok")
p=[r.get("post_s",0) for r in rows if r.get("type")=="sandbox" and r.get("status")=="ok"]; p.sort()
q=lambda a,x: a[min(len(a)-1,int(x*len(a)))]
print(f"p50={q(ok,.5):.2f} p95={q(ok,.95):.2f} max={ok[-1]:.2f} accept_p50={q(p,.5):.2f}" if ok else "no-ok")
PY
}
SL=/sys/fs/cgroup/rlp.slice
CLIENT_CPUS=0-351; CLIENT_MEMS=0-1
cp_pin() { # $1 cpus  $2 mems : API, proxy (systemd runtime cpuset), postgres + nats (docker cpuset), client (taskset/numactl)
  local u; for u in rlp-api.service rlp-proxy.service; do
    sudo systemctl set-property --runtime $u AllowedCPUs="$1" AllowedMemoryNodes="$2" || { say "FATAL set-property $u"; exit 1; }; done
  sudo docker update --cpuset-cpus "$1" --cpuset-mems "$2" rlp-postgres rlp-nats >/dev/null || { say "FATAL docker update"; exit 1; }
  CLIENT_CPUS=$1; CLIENT_MEMS=$2; }
where() { local p=$1; awk '/Cpus_allowed_list|Mems_allowed_list/{printf "%s ", $2}' /proc/$p/status; }
pin() { # $1 cpus  $2 mems   (no runner restart: cpuset applies to member tasks immediately; new FCs inherit)
  grep -qw cpuset /sys/fs/cgroup/cgroup.subtree_control || echo +cpuset | sudo tee /sys/fs/cgroup/cgroup.subtree_control >/dev/null
  grep -qw cpuset $SL/cgroup.subtree_control || echo +cpuset | sudo tee $SL/cgroup.subtree_control >/dev/null
  echo "$1" | sudo tee $SL/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/cpuset.mems >/dev/null
  if [ -d $SL/vms ]; then grep -qw cpuset $SL/vms/cgroup.subtree_control || echo +cpuset | sudo tee $SL/vms/cgroup.subtree_control >/dev/null 2>&1
    echo "$1" | sudo tee $SL/vms/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/vms/cpuset.mems >/dev/null; fi; }
run_arm() { # $1 name  $2 sandbox cpus  $3 sandbox mems  $4 cp cpus  $5 cp mems  $6 reps
  local name=$1 reps=$6 arm=$OUT/$1; mkdir -p $arm
  clean; pin "$2" "$3"; cp_pin "$4" "$5"; sleep 5
  say "ARM $name"
  say "  runner+vms : slice=$(cat $SL/cpuset.cpus.effective) mems=$(cat $SL/cpuset.mems.effective) runner=[$(where $(pgrep -nx rlp-runner))]"
  local want_cp=$(echo "$4" | sed 's/,/ /') got
  for p in $(pgrep -nx rlp-api) $(pgrep -nx rlp-proxy) $(sudo docker inspect -f {{.State.Pid}} rlp-postgres) $(sudo docker inspect -f {{.State.Pid}} rlp-nats); do
    got=$(awk '/Cpus_allowed_list/{print $2}' /proc/$p/status); [ "$got" = "$4" ] || { say "FATAL ctrl-plane pid $p on $got, want $4"; return 1; }; done
  [ "$(cat $SL/cpuset.cpus.effective)" = "$2" ] || { say "FATAL rlp.slice on $(cat $SL/cpuset.cpus.effective), want $2"; return 1; }
  say "  ctrl plane : api=[$(where $(pgrep -nx rlp-api))] proxy=[$(where $(pgrep -nx rlp-proxy))] pg=[$(where $(sudo docker inspect -f {{.State.Pid}} rlp-postgres))] nats=[$(where $(sudo docker inspect -f {{.State.Pid}} rlp-nats))] client=[$CLIENT_CPUS mems $CLIENT_MEMS]"
  clean; fleet 10 $arm/warm.jsonl; say "  warm: $(summ $arm/warm.jsonl)"
  for r in $(seq 1 $reps); do
    clean; sleep 2
    local ok=0; for w in $(seq 1 30); do sudo /usr/local/bin/bench-preflight $arm/pf$r >/dev/null && { ok=1; break; }; sleep 10; done
    [ $ok = 1 ] || { say "  PREFLIGHT still failing after 5m rep$r: $(grep FAIL $arm/pf$r/preflight.txt | tr '\n' ' ')"; return 1; }
    local rows=$(PG "select count(*) from vms") ev=$(PG "select count(*) from events" 2>/dev/null)
    local t0=$(date -u +%s); fleet 1000 $arm/rep$r.jsonl; local t1=$(date -u +%s)
    sudo journalctl -u rlp-runner --no-pager -o cat --since "@$t0" --until "@$((t1+5))" > $arm/rep$r.journal 2>/dev/null || true
    say "  $name rep$r $(summ $arm/rep$r.jsonl) $(pct $arm/rep$r.jsonl) socktmo=$(grep -c 'fc.sock not accepting' $arm/rep$r.journal || true) cordons=$(grep -c 'self-cordon entered' $arm/rep$r.journal || true) vms_rows_before=$rows events_rows_before=${ev:-?} api_up=$(ps -o etime= -p $(pgrep -nx rlp-api) | tr -d ' ')"
  done
}
ALL=0-351; S0=0-87,176-263; S1=88-175,264-351
S0_VM=0-71,176-247; S0_CP=72-87,248-263          # 72 cores runner+sandboxes / 16 cores control plane, all socket 0
restore() { pin $ALL 0-1; cp_pin $ALL 0-1; say "pins restored (slice=$(cat $SL/cpuset.cpus.effective), api=[$(where $(pgrep -nx rlp-api))])"; }
trap restore EXIT
run_arm A-REF       $S0    0 $ALL  0-1 3
run_arm B-CP-S1     $S0    0 $S1   1   3
run_arm C-S0-SHARED $S0    0 $S0   0   3
run_arm D-S0-SPLIT  $S0_VM 0 $S0_CP 0  3
clean
say "DONE -> $OUT"
