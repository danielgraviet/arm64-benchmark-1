#!/bin/bash
# 1k burst A/B on HQ Vera: placement (rlp.slice pinned to socket 0 vs unpinned) x JetStream create-consumer
# MaxAckPending (RLP_VM_MAXACK default 256 vs 1024; worker pool RLP_VM_CONCURRENCY=512). Client: mpfleet.py --procs 16
# so client pacing does not cap clone starts. Per-clone phase profile from the runner journal (burst-profile2.py).
set -u
BD=/home/daytona/arm64-benchmark-1; API=http://127.0.0.1:8088; SL=/sys/fs/cgroup/rlp.slice
REPS=${REPS:-2}; ARMS=${ARMS:-"UNPIN:256 UNPIN:1024 PIN:256 PIN:1024"}
OUT=/mnt/data/bench/burst-ab-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(sudo cat /etc/rlp/bench-api-key)
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
renv() { sudo cat /proc/$(pgrep -nx $1)/environ 2>/dev/null | tr '\0' '\n' | grep -oP "^$2=\K.*"; }
POOL_WANT=$(sudo grep -oP '^RLP_NETNS_POOL=\K[0-9]+' /etc/rlp/runner.env)
clean() { local i; for i in $(seq 1 60); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id & done; wait
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done; say "WARN $(pgrep -c firecracker) firecrackers left"; }
wait_ready() { local n s; for i in $(seq 1 240); do n=$(sudo ip netns list | wc -l); s=$(PG "select status from runners limit 1")
    curl -fsS -m2 $API/health >/dev/null 2>&1 && [ "$s" = online ] && [ "$n" -ge $((POOL_WANT*95/100)) ] && { sleep 10; return 0; }; sleep 5; done
  say "WARN not ready: runner=$s pool=$n/$POOL_WANT"; return 1; }
pin() { # $1 cpus $2 mems
  grep -qw cpuset /sys/fs/cgroup/cgroup.subtree_control || echo +cpuset | sudo tee /sys/fs/cgroup/cgroup.subtree_control >/dev/null
  grep -qw cpuset $SL/cgroup.subtree_control || echo +cpuset | sudo tee $SL/cgroup.subtree_control >/dev/null
  echo "$1" | sudo tee $SL/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/cpuset.mems >/dev/null
  if [ -d $SL/vms ]; then grep -qw cpuset $SL/vms/cgroup.subtree_control || echo +cpuset | sudo tee $SL/vms/cgroup.subtree_control >/dev/null 2>&1
    echo "$1" | sudo tee $SL/vms/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/vms/cpuset.mems >/dev/null; fi; }
ALL=0-351; S0=0-87,176-263
cleanup() { pin $ALL 0-1; sudo rm -f /etc/systemd/system/rlp-runner.service.d/zz-arm.conf /etc/rlp/arm-runner.env
  sudo systemctl daemon-reload; sudo systemctl restart rlp-runner; }
trap 'rc=$?; cleanup; say "SCRIPT EXIT rc=$rc (unpinned, RLP_VM_MAXACK override removed, runner restarted)"' EXIT
fleet() { ( cd $BD && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 RLP_HTTP_MAX_CONNECTIONS=1024 \
      RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0 && set -a && . ./.env && set +a && ulimit -n 1048576 && \
    timeout 600 uv run python mpfleet.py --procs 16 --count $1 --output $2 ) > $2.log 2>&1
  python3 -c "import json,sys;s=[json.loads(l) for l in open(sys.argv[1])][-1];print('ok=%d failed=%d wall=%.2f create_p50=%.2f p95=%.2f post_p50=%.2f'%(s['ok'],s['failed'],s['ready_wall_s'],s['create_p50_s'],s['create_p95_s'],s['post_p50_s']))" $2 2>/dev/null || echo "no-summary"; }
for spec in $ARMS; do
  place=${spec%%:*}; ack=${spec##*:}; name=$place-ACK$ack; arm=$OUT/$name; mkdir -p $arm
  clean
  printf 'RLP_VM_MAXACK=%s\nRLP_FC_SOCK_WAIT_MS=30000\n' $ack | sudo tee /etc/rlp/arm-runner.env >/dev/null
  printf '[Service]\nEnvironmentFile=/etc/rlp/arm-runner.env\n' | sudo tee /etc/systemd/system/rlp-runner.service.d/zz-arm.conf >/dev/null
  if [ $place = PIN ]; then pin $S0 0; else pin $ALL 0-1; fi
  sudo systemctl daemon-reload; sudo systemctl restart rlp-runner; sleep 5
  [ "$(renv rlp-runner RLP_VM_MAXACK)" = $ack ] || { say "FATAL $name: RLP_VM_MAXACK=$(renv rlp-runner RLP_VM_MAXACK)"; exit 1; }
  wait_ready || exit 1
  say "ARM $name: slice=$(cat $SL/cpuset.cpus.effective) mems=$(cat $SL/cpuset.mems.effective) runner=$(awk '/Cpus_allowed_list/{print $2}' /proc/$(pgrep -nx rlp-runner)/status) maxack=$(renv rlp-runner RLP_VM_MAXACK)"
  clean; say "  warm: $(fleet 10 $arm/warm.jsonl)"
  for r in $(seq 1 $REPS); do
    clean; sleep 2
    sudo /usr/local/bin/bench-preflight $arm/pf$r >/dev/null || say "  preflight FAIL: $(grep FAIL $arm/pf$r/preflight.txt | tr '\n' ' ')"
    t0=$(date -u +%s); res=$(fleet 1000 $arm/rep$r.jsonl); t1=$(date -u +%s)
    sudo journalctl -u rlp-runner --no-pager -o cat --since "@$t0" --until "@$((t1+5))" > $arm/rep$r.journal 2>/dev/null
    prof=$(python3 /home/daytona/burst-profile2.py $arm/rep$r.journal 2>/dev/null | grep -E "START|peak" | tr -s ' ' | tr '\n' ' ')
    say "  $name rep$r $res | $prof"
  done
done
clean; say "DONE -> $OUT"
