#!/bin/bash
# One create-path measurement run on HQ Vera.  usage: steps-run.sh <tag> <seq|burst> <count> <image> [procs]
set -u
TAG=$1; MODE=$2; COUNT=$3; IMG=$4; PROCS=${5:-16}
API=http://127.0.0.1:8088; S=/home/daytona/steps
OUT=/mnt/data/bench/steps-$(date -u +%Y%m%d_%H%M%S)-$TAG; sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(grep -oP '^VERA_RLP_API_KEY=\K.*' /home/daytona/arm64-benchmark-1/.env | tr -d '"')
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
clean() { local i; for i in $(seq 1 60); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id & done; wait
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done; say "WARN $(pgrep -c firecracker) firecrackers left"; }
clean
for w in $(seq 1 30); do sudo /usr/local/bin/bench-preflight $OUT/pf >/dev/null 2>&1 && break; sleep 10; done
say "run $TAG mode=$MODE count=$COUNT image=$IMG procs=$PROCS preflight=$(grep -q 'PREFLIGHT PASS' $OUT/pf/preflight.txt && echo PASS || grep FAIL $OUT/pf/preflight.txt | tr '\n' ' ') slice=$(cat /sys/fs/cgroup/rlp.slice/cpuset.cpus.effective)"
TOK=$(sudo cat /proc/$(pgrep -nx rlp-runner)/cmdline | tr '\0' '\n' | grep -A1 '^-token$' | tail -1)
$S/natstap/natstap -token "$TOK" -out $OUT/tap.tsv 2> $OUT/tap.err & TP=$!; sleep 1
T0=$(date -u +%s)
( cd $S && ulimit -n 1048576 && /home/daytona/arm64-benchmark-1/.venv/bin/python stepclient.py --mode $MODE --count $COUNT \
    --procs $PROCS --image $IMG --out $OUT/client.jsonl ) > $OUT/client.log 2>&1
say "client: $(tail -1 $OUT/client.log)"
sleep 5; kill $TP; wait $TP 2>/dev/null
sudo journalctl -u rlp-runner --since "@$((T0-1))" --no-pager -o cat | grep -E 'msg=("boot-phases|boot-phases|running-emit)' > $OUT/runner.log
bash $S/steps-dbexport.sh $OUT >> $OUT/log
say "runner lines=$(wc -l < $OUT/runner.log) tap lines=$(wc -l < $OUT/tap.tsv)"
clean
python3 $S/steps-analyze.py $OUT > $OUT/report.txt 2>&1; cat $OUT/report.txt
say "DONE -> $OUT"
