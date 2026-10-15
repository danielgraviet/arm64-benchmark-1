#!/bin/bash
# One pinned (socket 0) 1k burst with a host-wide CPU profile: where does the ~10 s / ~100 clones/s go?
# perf record -a -g on socket-0 CPUs for the burst window; summaries by comm and by symbol (kernel + user).
set -u
BD=/home/daytona/arm64-benchmark-1; API=http://127.0.0.1:8088; SL=/sys/fs/cgroup/rlp.slice
OUT=/mnt/data/bench/perf-burst-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(sudo cat /etc/rlp/bench-api-key)
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
clean() { local i; for i in $(seq 1 60); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id & done; wait
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done; }
pin() { echo "$1" | sudo tee $SL/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/cpuset.mems >/dev/null
  echo "$1" | sudo tee $SL/vms/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/vms/cpuset.mems >/dev/null; }
trap 'rc=$?; pin 0-351 0-1; say "SCRIPT EXIT rc=$rc (unpinned)"' EXIT
fleet() { ( cd $BD && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 RLP_HTTP_MAX_CONNECTIONS=1024 \
      RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0 && set -a && . ./.env && set +a && ulimit -n 1048576 && \
    timeout 600 uv run python mpfleet.py --procs 16 --count $1 --output $2 ) > $2.log 2>&1; tail -1 $2 | cut -c1-200; }
clean; pin 0-87,176-263 0; sleep 5
say "pinned: slice=$(cat $SL/cpuset.cpus.effective) runner=$(awk '/Cpus_allowed_list/{print $2}' /proc/$(pgrep -nx rlp-runner)/status)"
say "warm: $(fleet 10 $OUT/warm.jsonl)"; clean
for w in $(seq 1 30); do sudo /usr/local/bin/bench-preflight $OUT/pf >/dev/null && break; sleep 10; done
grep -q "PREFLIGHT PASS" $OUT/pf/preflight.txt && say "preflight PASS" || say "preflight: $(grep FAIL $OUT/pf/preflight.txt | tr '\n' ' ')"
# client on socket 1 so it does not show up in the socket-0 profile
sudo perf record -B -N -a -g -F 499 -C 0-87,176-263 -o $OUT/perf.data -- sleep 14 > $OUT/perf-record.log 2>&1 &
PP=$!; sleep 1
t0=$(date -u +%s); say "burst: $(taskset -c 88-175,264-351 bash -c "$(declare -f fleet); BD=$BD; fleet 1000 $OUT/burst.jsonl")"; t1=$(date -u +%s)
wait $PP
sudo journalctl -u rlp-runner --no-pager -o cat --since "@$t0" --until "@$((t1+5))" > $OUT/burst.journal 2>/dev/null
python3 /home/daytona/burst-profile.py $OUT/burst.journal > $OUT/profile.txt 2>&1
sudo perf report -i $OUT/perf.data --no-children --sort comm --stdio 2>/dev/null | grep -v "^#" | grep -v "^$" | head -25 > $OUT/by-comm.txt
sudo perf report -i $OUT/perf.data --no-children --sort sym --stdio -g none 2>/dev/null | grep -v "^#" | grep -v "^$" | head -60 > $OUT/by-sym.txt
sudo perf report -i $OUT/perf.data --no-children --sort comm,sym --stdio -g none 2>/dev/null | grep -v "^#" | grep -v "^$" | head -60 > $OUT/by-comm-sym.txt
sudo chown -R $(id -u):$(id -g) $OUT
clean; say "DONE -> $OUT"
