#!/bin/bash
# phoenix-e6: (A) true startup with an idle-entrypoint image, and (B) the concurrency ceiling.
# Per docs/benchmark-methodology.md §0, the agent image runs a CPU-bound entrypoint in every
# sandbox, so a ladder with it measures startup-under-load. The ceiling ladder uses alpine.
set -u
BD=/home/ubuntu/arm64-benchmark-1; API=http://127.0.0.1:8088
OUT=/mnt/data/bench/ladder-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(sudo cat /etc/rlp/bench-api-key)
exec 9>/tmp/ph-ladder.lock; flock -n 9 || { echo 'another ph-ladder run holds the lock'; exit 1; }
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
clean() { local i; for i in $(seq 1 120); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id; done
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done
  say "  WARN killing $(pgrep -c firecracker) orphans"; sudo pkill -x firecracker; sleep 10; sudo rm -rf /run/fc/* 2>/dev/null
  PG "update vms set status='deleted' where status not in ('deleted','failed','lost')" >/dev/null; }
# $1 count  $2 procs  $3 image  $4 out
mpf() { ( cd $BD && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 MPFLEET_IMAGE="$3" && set -a && . ./.env && set +a && ulimit -n 1048576 && \
    timeout 900 uv run python mpfleet.py --target phoenix-e6 --count $1 --procs $2 --timeout 300 --probe-timeout 120 --output $4 ) > $4.log 2>&1; }
peak() { # sample fc count + memory while a run is in flight
  local f=$1; : > $f; while :; do echo "$(date -u +%T) fc=$(pgrep -c firecracker) memavail_gib=$(awk '/MemAvailable/{printf "%d",$2/1048576}' /proc/meminfo) load=$(cut -d' ' -f1 /proc/loadavg) netns=$(ip netns list 2>/dev/null | wc -l)" >> $f; sleep 2; done; }
lvl() { # $1 count  $2 image  $3 tag
  local n=$1 img=$2 tag=$3
  local f=$OUT/$tag-$n.jsonl
  clean; sleep 3
  sudo /usr/local/bin/bench-preflight $OUT/pf-$tag-$n >/dev/null || say "  (preflight: $(grep FAIL $OUT/pf-$tag-$n/preflight.txt | awk '{print $1}' | tr '\n' ' '))"
  peak $f.sample & local sp=$!
  local t0=$(date -u +%s); mpf $n 16 "$img" $f; local t1=$(date -u +%s)
  kill $sp 2>/dev/null
  sudo journalctl -u rlp-runner --no-pager -o cat --since "@$t0" --until "@$((t1+5))" > $f.journal 2>/dev/null
  local s=$(grep -o '"ok": [0-9]*, "failed": [0-9]*, "ready_wall_s": [0-9.]*' $f.log | tail -1)
  [ -n "$s" ] || s="NO SUMMARY: $(tail -2 $f.log | tr '\n' ' ' | cut -c1-160)"
  say "$tag n=$n $s wall=$((t1-t0))s peak_fc=$(awk -F'fc=' '{split($2,a," ");if(a[1]+0>m)m=a[1]}END{print m+0}' $f.sample) min_memavail_gib=$(awk -F'memavail_gib=' '{split($2,a," ");if(m==""||a[1]+0<m)m=a[1]+0}END{print m+0}' $f.sample) socktmo=$(grep -c 'fc.sock not accepting' $f.journal) cordons=$(grep -c 'self-cordon entered' $f.journal) nocap=$(grep -c 'no matching capacity' $f.log) df=$(df -h --output=avail /mnt/data | tail -1 | tr -d ' ')"
}

say "=== A. true startup, idle image (alpine:3.20), whole box — comparable to HQ Vera 4.0-4.2s / 9575F 4.0s"
for r in 1 2; do lvl 1000 alpine:3.20 idle1k-r$r; done
lvl 2000 alpine:3.20 idle2k

say "=== B. concurrency ceiling, idle image. Capacity now: MAX_LIVE_VMS=$(tr '\0' '\n' </proc/$(pgrep -nx rlp-runner)/environ | grep -oP '^RLP_MAX_LIVE_VMS=\K.*') NETNS_POOL=$(tr '\0' '\n' </proc/$(pgrep -nx rlp-runner)/environ | grep -oP '^RLP_NETNS_POOL=\K.*')"
for n in 3000 4000 5000 6000; do
  lvl $n alpine:3.20 ceil
  ok=$(grep -o '"ok": [0-9]*' $OUT/ceil-$n.jsonl.log | tail -1 | grep -oE '[0-9]+')
  [ "${ok:-0}" -lt "$n" ] && { say "  STOP: level $n landed ${ok:-0}/$n — ceiling reached"; break; }
done
clean
say "DONE -> $OUT"
