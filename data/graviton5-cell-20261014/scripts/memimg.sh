# Private (CoW) host memory of one clone, 15 s after create, per image.
K=$(sudo cat /etc/rlp/bench-api-key)
for IMG in python:3.12-slim dtgraviet/vera-agent-benchmark:v3; do
ID=$(curl -s -m 60 -X POST http://127.0.0.1:8088/vms -H "Authorization: Bearer $K" -H 'Content-Type: application/json' -d "{\"image\":\"$IMG\",\"name\":\"mi\",\"cpu\":0.025,\"vcpus_max\":1,\"mem_mib\":64,\"mem_max_mib\":4096,\"scratch_mib\":1024,\"cpu_arch\":\"arm64\",\"cpu_type\":\"graviton5\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['vm_id'])")
sleep 15
P=$(for x in $(pgrep -x firecracker); do sudo readlink /proc/$x/cwd 2>/dev/null | grep -q $ID && echo $x; done | head -1)
read -r u s < <(sudo awk '{print $14, $15}' /proc/$P/stat)
echo "$IMG page=$(getconf PAGESIZE): $(sudo awk '/^Rss/{r=$2}/^Private_Dirty/{d=$2}END{printf "rss=%dMiB private_dirty=%dMiB", r/1024, d/1024}' /proc/$P/smaps_rollup) fc_cpu=$(echo "($u+$s)/100" | bc -l | cut -c1-5)s"
curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" http://127.0.0.1:8088/vms/$ID
done
