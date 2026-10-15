K=$(sudo cat /etc/rlp/bench-api-key); T=$(getconf CLK_TCK)
ID=$(curl -s -m 60 -X POST http://127.0.0.1:8088/vms -H "Authorization: Bearer $K" -H 'Content-Type: application/json' -d '{"image":"dtgraviet/vera-agent-benchmark:v3","name":"entry","cpu":0.025,"vcpus_max":1,"mem_mib":64,"mem_max_mib":4096,"scratch_mib":1024,"cpu_arch":"arm64","cpu_type":"graviton5"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['vm_id'])")
P=""; for i in $(seq 1 50); do P=$(for x in $(pgrep -x firecracker); do sudo readlink /proc/$x/cwd 2>/dev/null | grep -q $ID && echo $x; done | head -1); [ -n "$P" ] && break; sleep 0.1; done
t0=$(date +%s.%N)
for i in $(seq 1 16); do read -r u s < <(sudo awk '{print $14, $15}' /proc/$P/stat); printf "t=%4.1fs fc_cpu=%5.2fs dirty=%sMiB\n" $(echo "$(date +%s.%N)-$t0"|bc) $(echo "($u+$s)/$T"|bc -l) $(sudo awk '/^Private_Dirty/{print int($2/1024)}' /proc/$P/smaps_rollup); sleep 0.5; done
curl -s -m 30 -X POST "http://127.0.0.1:9000/toolbox/$ID/process/execute" -H "Authorization: Bearer $K" -H 'Content-Type: application/json' -d '{"command":"for p in /proc/[0-9]*; do c=$(tr \"\\0\" \" \" < $p/cmdline 2>/dev/null); [ -n \"$c\" ] && echo \"${p#/proc/} $c\"; done | head -20; ls -la /tmp /app 2>/dev/null | head; cat /proc/1/cmdline | tr \"\\0\" \" \""}' | python3 -c "import sys,json;print(json.load(sys.stdin).get('result'))"
sudo cat $(sudo readlink /proc/$P/cwd)/serial.log | tail -5
curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" http://127.0.0.1:8088/vms/$ID
