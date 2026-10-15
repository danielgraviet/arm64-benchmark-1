K=$(sudo cat /etc/rlp/bench-api-key)
ID=$(curl -s -m 60 -X POST http://127.0.0.1:8088/vms -H "Authorization: Bearer $K" -H 'Content-Type: application/json' -d '{"image":"dtgraviet/vera-agent-benchmark:v3","name":"pmap","cpu":0.025,"vcpus_max":1,"mem_mib":64,"mem_max_mib":4096,"scratch_mib":1024,"cpu_arch":"arm64","cpu_type":"graviton5"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['vm_id'])")
sleep 15
P=$(for x in $(pgrep -x firecracker); do sudo readlink /proc/$x/cwd 2>/dev/null | grep -q $ID && echo $x; done | head -1)
sudo python3 ~/rlp-build/pmap.py $P
curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" http://127.0.0.1:8088/vms/$ID
