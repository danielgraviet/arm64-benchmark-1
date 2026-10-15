S=/home/daytona/steps; OUT=/mnt/data/bench/wake-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
sudo bpftrace $S/wake.bt > $OUT/wake.txt 2> $OUT/wake.err & sleep 5
T0=$(date -u +%s)
( cd $S && ~/arm64-benchmark-1/.venv/bin/python stepclient.py --mode seq --count 30 --gap 1.0 --image alpine:3.20 --out $OUT/client.jsonl )
sleep 1; sudo kill -INT $(pgrep -x bpftrace); sleep 2
sudo journalctl -u rlp-runner --since "@$((T0-1))" --no-pager -o cat | grep -E 'msg=(boot-phases |running-emit)' > $OUT/runner.log
sudo chown $(id -u):$(id -g) $OUT/*; wc -l $OUT/wake.txt; head -3 $OUT/wake.err; echo $OUT
