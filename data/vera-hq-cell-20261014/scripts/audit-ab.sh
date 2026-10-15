#!/bin/bash
# Event-audit A/B on HQ Vera: ON (fresh API) / OFF (fresh API) / ON (fresh API, 6 reps -> drift without restart).
# Only rlp-api restarts between arms; runner, netns pool and templates stay warm. Preflight gates every rep.
set -u
BD=/home/daytona/arm64-benchmark-1; API=http://127.0.0.1:8088
OUT=/mnt/data/bench/audit-ab-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(sudo cat /etc/rlp/bench-api-key)
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
trap 'rc=$?; say "SCRIPT EXIT rc=$rc"' EXIT
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
renv() { sudo cat /proc/$(pgrep -nx $1)/environ 2>/dev/null | tr '\0' '\n' | grep -oP "^$2=\K.*"; }
clean() { local i; for i in $(seq 1 60); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id; done
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done
  say "WARN killing $(pgrep -c firecracker) orphans"; sudo pkill -x firecracker; sleep 5; sudo rm -rf /run/fc/* 2>/dev/null
  PG "update vms set status='deleted' where status not in ('deleted','failed','lost')" >/dev/null; }
fleet() { ( cd $BD && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 RLP_HTTP_MAX_CONNECTIONS=1024 \
      RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0 && set -a && . ./.env && set +a && ulimit -n 1048576 && \
    timeout 420 uv run python scripts/rlp_light_create_fleet.py --target vera --count $1 --workers $1 \
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
run_arm() { # $1 name  $2 audit(1|0)  $3 reps
  local name=$1 audit=$2 reps=$3 arm=$OUT/$1; mkdir -p $arm
  if [ $audit = 0 ]; then
    printf 'RLP_EVENT_AUDIT=0\n' | sudo tee /etc/rlp/arm-api.env >/dev/null
    printf '[Service]\nEnvironmentFile=/etc/rlp/arm-api.env\n' | sudo tee /etc/systemd/system/rlp-api.service.d/zz-arm.conf >/dev/null
  else sudo rm -f /etc/systemd/system/rlp-api.service.d/zz-arm.conf /etc/rlp/arm-api.env; fi
  clean; sudo systemctl daemon-reload; sudo systemctl restart rlp-api
  for i in $(seq 1 60); do curl -fsS -m2 $API/health >/dev/null 2>&1 && break; sleep 2; done; sleep 10
  local eff=$(renv rlp-api RLP_EVENT_AUDIT)
  if [ $audit = 0 ] && [ "$eff" != 0 ]; then say "FATAL audit-off not applied (got '${eff}')"; return 1; fi
  if [ $audit = 1 ] && [ -n "$eff" ] && [ "$eff" != 1 ]; then say "FATAL audit-on not applied (got '${eff}')"; return 1; fi
  say "ARM $name: RLP_EVENT_AUDIT=${eff:-unset(default on)} api_pid=$(pgrep -nx rlp-api) api_up=$(ps -o etime= -p $(pgrep -nx rlp-api) | tr -d ' ')"
  clean; fleet 10 $arm/warm.jsonl; say "  warm: $(summ $arm/warm.jsonl)"
  for r in $(seq 1 $reps); do
    clean; sleep 2
    sudo /usr/local/bin/bench-preflight $arm/pf$r >/dev/null || { say "  PREFLIGHT FAIL rep$r: $(grep FAIL $arm/pf$r/preflight.txt | tr '\n' ' ')"; return 1; }
    local rows=$(PG "select count(*) from vms") ev=$(PG "select count(*) from events" 2>/dev/null)
    local t0=$(date -u +%s); fleet 1000 $arm/rep$r.jsonl; local t1=$(date -u +%s)
    sudo journalctl -u rlp-runner --no-pager -o cat --since "@$t0" --until "@$((t1+5))" > $arm/rep$r.journal 2>/dev/null || true
    say "  $name rep$r $(summ $arm/rep$r.jsonl) $(pct $arm/rep$r.jsonl) socktmo=$(grep -c 'fc.sock not accepting' $arm/rep$r.journal || true) cordons=$(grep -c 'self-cordon entered' $arm/rep$r.journal || true) vms_rows_before=$rows events_rows_before=${ev:-?} api_up=$(ps -o etime= -p $(pgrep -nx rlp-api) | tr -d ' ')"
  done
}
run_arm ON-1 1 3
run_arm OFF  0 3
run_arm ON-2 1 6
sudo rm -f /etc/systemd/system/rlp-api.service.d/zz-arm.conf /etc/rlp/arm-api.env; sudo systemctl daemon-reload; sudo systemctl restart rlp-api; clean
say "DONE -> $OUT (audit override removed; default on)"
