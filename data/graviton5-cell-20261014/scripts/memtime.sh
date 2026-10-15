K=$(sudo cat /etc/rlp/bench-api-key); A=http://127.0.0.1:8088
ID=$(curl -s -m 60 -X POST $A/vms -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
  -d '{"image":"dtgraviet/vera-agent-benchmark:v3","name":"memtime2","cpu":0.025,"vcpus_max":1,"mem_mib":64,"mem_max_mib":4096,"scratch_mib":1024,"cpu_arch":"arm64","cpu_type":"graviton5"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['vm_id'])")
[ -z "$ID" ] && { echo create failed; exit 1; }
t0=$(date +%s.%N)
pd() { local p=$(for x in $(pgrep -x firecracker); do sudo readlink /proc/$x/cwd 2>/dev/null | grep -q $ID && echo $x; done | head -1); [ -n "$p" ] && sudo awk '/^Private_Dirty/{d=$2}/^Rss/{r=$2}END{printf "rss=%dMiB dirty=%dMiB", r/1024, d/1024}' /proc/$p/smaps_rollup; }
for i in $(seq 1 12); do printf "t=%5.1fs %s status=%s\n" $(echo "$(date +%s.%N)-$t0" | bc) "$(pd)" "$(curl -s -m 5 -H "Authorization: Bearer $K" $A/vms/$ID | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status"))')"; sleep 0.5; done
echo "-- exec echo ready"; curl -s -m 30 -X POST "http://127.0.0.1:9000/toolbox/$ID/process/execute" -H "Authorization: Bearer $K" -H 'Content-Type: application/json' -d '{"command":"echo ready"}' >/dev/null
sleep 1; echo "after echo: $(pd)"
curl -s -m 30 -X POST "http://127.0.0.1:9000/toolbox/$ID/process/execute" -H "Authorization: Bearer $K" -H 'Content-Type: application/json' -d '{"command":"python3 -c \"print(1)\""}' >/dev/null
sleep 1; echo "after python: $(pd)"
sleep 20; echo "after 20s idle: $(pd)"
curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $A/vms/$ID
