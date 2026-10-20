#!/bin/bash
# 40 sequential alpine creates with a root-ns capture of toolbox probes (tcp/2280) + ARP, to explain the 580 ms toolbox wait.
OUT=/mnt/data/bench/tbpcap-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
sudo timeout 120 tcpdump -i any -nn -tt -s 96 -w $OUT/cap.pcap 'tcp port 2280 or arp' 2> $OUT/tcpdump.err & TD=$!; sleep 2
T0=$(date -u +%s)
( cd ~/steps && ~/arm64-benchmark-1/.venv/bin/python stepclient.py --mode seq --count 40 --image alpine:3.20 --out $OUT/client.jsonl )
sleep 1; sudo kill -INT $TD 2>/dev/null; sleep 2
sudo journalctl -u rlp-runner --since "@$((T0-1))" --no-pager -o cat | grep -E 'msg=boot-phases ' > $OUT/runner.log
IDS=$(python3 -c "import json,sys;print(','.join(json.loads(l)['vm_id'] for l in open(sys.argv[1]) if '\"vm_id\"' in l))" $OUT/client.jsonl)
sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tA -F, -c "select id, host(vm_ip) from vms where id = any(string_to_array('$IDS', ',')::uuid[])" > $OUT/ips.csv
sudo tcpdump -nn -tt -r $OUT/cap.pcap 2>/dev/null > $OUT/cap.txt; sudo chown $(id -u):$(id -g) $OUT/*
echo $OUT
