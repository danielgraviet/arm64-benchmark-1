#!/bin/bash
# 1k/2k create-ready, whole box and socket 0, 16-process client. Second headline number.
set -u
BD=/home/ubuntu/arm64-benchmark-1; API=http://127.0.0.1:8088
OUT=/mnt/data/bench/burst2k-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(sudo cat /etc/rlp/bench-api-key); SL=/sys/fs/cgroup/rlp.slice
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
clean() { local i; for i in $(seq 1 60); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id; done
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done
  sudo pkill -x firecracker; sleep 5; sudo rm -rf /run/fc/* 2>/dev/null
  PG "update vms set status='deleted' where status not in ('deleted','failed','lost')" >/dev/null; }
mpf() { ( cd $BD && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 && set -a && . ./.env && set +a && ulimit -n 1048576 && \
    timeout 600 uv run python mpfleet.py --target phoenix-e6 --count $1 --procs $2 --output $3 ) > $3.log 2>&1; }
pin() { grep -qw cpuset /sys/fs/cgroup/cgroup.subtree_control || echo +cpuset | sudo tee /sys/fs/cgroup/cgroup.subtree_control >/dev/null
  grep -qw cpuset $SL/cgroup.subtree_control || echo +cpuset | sudo tee $SL/cgroup.subtree_control >/dev/null
  echo "$1" | sudo tee $SL/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/cpuset.mems >/dev/null
  [ -d $SL/vms ] && { echo "$1" | sudo tee $SL/vms/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/vms/cpuset.mems >/dev/null; }
  for u in rlp-api rlp-proxy; do sudo systemctl set-property --runtime $u AllowedCPUs="$1" >/dev/null 2>&1; sudo systemctl set-property --runtime $u AllowedMemoryNodes="$2" >/dev/null 2>&1; done
  for c in rlp-postgres rlp-nats; do sudo docker update --cpuset-cpus "$1" --cpuset-mems "$2" $c >/dev/null 2>&1; done; }
for arm in "UNPIN 0-383 0-1" "PIN-S0 0-95,192-287 0"; do
  set -- $arm; name=$1; pin "$2" "$3"; sleep 3
  for n in 1000 2000; do for r in 1 2; do
    clean; sleep 3; sudo /usr/local/bin/bench-preflight $OUT/pf-$name-$n-$r >/dev/null || say "  (preflight warn: $(grep FAIL $OUT/pf-$name-$n-$r/preflight.txt | tr '\n' ' '))"
    f=$OUT/$name-$n-r$r.jsonl; t0=$(date -u +%s); mpf $n 16 $f; t1=$(date -u +%s)
    sudo journalctl -u rlp-runner --no-pager -o cat --since "@$t0" --until "@$((t1+5))" > $f.journal 2>/dev/null
    say "$name n=$n rep$r $(grep -o '"ok": [0-9]*, "failed": [0-9]*, "ready_wall_s": [0-9.]*' $f.log | tail -1) socktmo=$(grep -c 'fc.sock not accepting' $f.journal) cordons=$(grep -c 'self-cordon entered' $f.journal) peak_fc=$(grep -c . /dev/null)"
  done; done
done
pin 0-383 0-1; clean; say "DONE -> $OUT"
