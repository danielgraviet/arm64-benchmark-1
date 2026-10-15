K=$(sudo cat /etc/rlp/bench-api-key)
ID=$(curl -s -m 60 -X POST http://127.0.0.1:8088/vms -H "Authorization: Bearer $K" -H 'Content-Type: application/json' -d '{"image":"dtgraviet/vera-agent-benchmark:v3","name":"gv","cpu":0.025,"vcpus_max":1,"mem_mib":64,"mem_max_mib":4096,"scratch_mib":1024,"cpu_arch":"arm64","cpu_type":"graviton5"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['vm_id'])")
sleep 8
ex() { curl -s -m 30 -X POST "http://127.0.0.1:9000/toolbox/$ID/process/execute" -H "Authorization: Bearer $K" -H 'Content-Type: application/json' -d "$(python3 -c 'import json,sys;print(json.dumps({"command":sys.argv[1]}))' "$1")" | python3 -c "import sys,json;print(json.load(sys.stdin).get('result'))"; }
ex 'ps -eo pid,rss,etimes,args --sort=-rss | head -12; echo; grep -E "^(MemTotal|MemFree|Cached|Buffers|AnonPages|Slab|SReclaimable|SUnreclaim|Mapped)" /proc/meminfo; grep -E "^(pgpgin|pgfault|pgalloc_normal|pgalloc_dma)" /proc/vmstat; cat /proc/cmdline; uptime; mount | grep -E "erofs|overlay| / " | head -5'
curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" http://127.0.0.1:8088/vms/$ID
