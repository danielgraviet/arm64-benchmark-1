#!/bin/bash
# Node-to-node network test across the atl1 nodes (run locally; orchestrates over ssh; set NODE<NNN>_PUB to the public IPs). Stock sysctls, MTU 1500.
#   1. latency, full mesh over the private network: ping (1,000 x 10 ms) and netperf TCP_RR (1-byte request/response)
#   2. throughput, private 10.46.90.x: 864<->861 at 1, 8, 64 flows, both directions; full mesh at 8 flows
#   3. throughput, public addresses (<nodeNNN-public>): 864->861 at 1 and 64 flows, both directions
#   4. two disjoint pairs at once (864->861 and 865->857, 64 flows each): is the fabric shared?
# Every iperf3 run is 15 s with 2 s omitted; numbers are the receiver-side sums.
set -u
OUT=/tmp/opencode/net/nodes-$(date -u +%Y%m%d_%H%M%S); mkdir -p $OUT
declare -A PRIV=([853]=10.46.90.70 [864]=10.46.90.71 [861]=10.46.90.72 [865]=10.46.90.73 [857]=10.46.90.74)
declare -A PUB=([853]="${NODE853_PUB:-<node853-public>}" [864]="${NODE864_PUB:-<node864-public>}" [861]="${NODE861_PUB:-<node861-public>}" [865]="${NODE865_PUB:-<node865-public>}" [857]="${NODE857_PUB:-<node857-public>}")
NODES="853 864 861 865 857"
S() { timeout ${T:-300} ssh -o BatchMode=yes root@${PUB[$1]} "$2"; }
say() { echo "$(date -u +%T) $*" | tee -a $OUT/summary.txt; }
servers() { for n in $NODES; do S $n 'pkill -x iperf3; sleep 0.5; for p in $(seq 5201 5216); do iperf3 -s -D -p $p; done; pgrep -c -x iperf3' >/dev/null & done; wait; }
# iperf $src $dst-ip $flows $dir(fwd|rev) $tag : 1 process up to 8 flows, otherwise 16 processes on 16 ports
iperf() { local src=$1 dst=$2 f=$3 dir=$4 tag=$5 procs per r=""; [ "$dir" = rev ] && r="-R"
  if [ $f -le 8 ]; then procs=1; per=$f; else procs=16; per=$((f/16)); fi
  S $src "for i in \$(seq 0 $((procs-1))); do iperf3 -c $dst -p \$((5201+i)) -P $per -t 15 -O 2 $r -J > /tmp/ip-\$i.json & done; wait
    python3 -c '
import json,sys
tot=0;rt=0
for i in range($procs):
    d=json.load(open(\"/tmp/ip-%d.json\"%i))
    if \"error\" in d: print(\"ERR\",d[\"error\"]); continue
    tot+=d[\"end\"][\"sum_received\"][\"bits_per_second\"]; rt+=d[\"end\"][\"sum_sent\"].get(\"retransmits\",0)
print(\"%.1f Gb/s retrans=%d\"%(tot/1e9,rt))'" > $OUT/$tag.txt 2>&1
  say "TPUT $tag flows=$f: $(tail -1 $OUT/$tag.txt)"; }

say "== 1. latency, private network, full mesh"
for a in $NODES; do for b in $NODES; do [ $a = $b ] && continue
  p=$(S $a "ping -q -c 1000 -i 0.01 ${PRIV[$b]} | tail -1 | cut -d= -f2")
  r=$(S $a "netperf -H ${PRIV[$b]} -l 10 -t TCP_RR -- -o MIN_LATENCY,P50_LATENCY,P99_LATENCY,MEAN_LATENCY,TRANSACTION_RATE | tail -1")
  say "LAT $a->$b ping min/avg/max/mdev(ms)=$p | tcp_rr min,p50,p99,mean(us),trans/s=$r"; done; done
servers
say "== 2. throughput, private network"
for f in 1 8 64; do iperf 864 ${PRIV[861]} $f fwd priv-864-861-f$f; iperf 864 ${PRIV[861]} $f rev priv-861-864-f$f; done
for a in $NODES; do for b in $NODES; do [ $a = $b ] && continue; iperf $a ${PRIV[$b]} 8 fwd mesh-$a-$b-f8; done; done
say "== 3. throughput, public addresses"
for f in 1 64; do iperf 864 ${PUB[861]} $f fwd pub-864-861-f$f; iperf 864 ${PUB[861]} $f rev pub-861-864-f$f; done
p=$(S 864 "ping -q -c 1000 -i 0.01 ${PUB[861]} | tail -1 | cut -d= -f2"); say "LAT public 864->861 ping=$p"
S 864 "mtr -n -r -c 20 ${PUB[861]}" > $OUT/mtr-pub-864-861.txt 2>&1
say "== 4. two disjoint pairs at once, 64 flows each"
iperf 864 ${PRIV[861]} 64 fwd pair2-864-861 & iperf 865 ${PRIV[857]} 64 fwd pair2-865-857 & wait
for n in $NODES; do S $n 'pkill -x iperf3' & done; wait
say "DONE -> $OUT"
