#!/bin/bash
# Reversible: permanent neighbour entry for the guest (10.255.0.2 -> AA:FC:0A:FF:00:02) in every pool netns.
S=/home/daytona/steps; OUT=/mnt/data/bench/neigh-ab-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
hist() { python3 -c "
import re,sys,collections
v=[int(m.group(1)) for m in (re.search(r'toolbox_wait_ms=(\d+)',l) for l in open(sys.argv[1])) if m]
s=sum(1 for x in v if x>100); print(f'n={len(v)} stalled(>100ms)={s} ({100*s/max(1,len(v)):.0f}%) max={max(v)} ms')" $1; }
run() { local T0=$(date -u +%s); ( cd $S && ~/arm64-benchmark-1/.venv/bin/python stepclient.py --mode seq --count 60 --gap 0.5 --image alpine:3.20 --out $OUT/$1.jsonl ) >/dev/null
  sudo journalctl -u rlp-runner --since "@$((T0-1))" --no-pager -o cat | grep 'msg=boot-phases ' > $OUT/$1.runner.log; echo "$1: $(hist $OUT/$1.runner.log)"; }
setall() { for ns in $(sudo ip netns list | awk '{print $1}'); do
    if [ $1 = add ]; then sudo ip netns exec $ns ip neigh replace 10.255.0.2 lladdr aa:fc:0a:ff:00:02 dev rlptap0 nud permanent 2>/dev/null
    else sudo ip netns exec $ns ip neigh del 10.255.0.2 dev rlptap0 2>/dev/null; fi; done; }
run baseline
setall add; echo "permanent entries: $(for ns in $(sudo ip netns list | awk '{print $1}' | shuf -n 20); do sudo ip netns exec $ns ip neigh show 10.255.0.2 dev rlptap0; done | grep -c PERMANENT)/20 sampled"
run permanent
setall del; echo "reverted: $(for ns in $(sudo ip netns list | awk '{print $1}' | shuf -n 20); do sudo ip netns exec $ns ip neigh show 10.255.0.2 dev rlptap0; done | grep -c PERMANENT)/20 still permanent"
run baseline2
