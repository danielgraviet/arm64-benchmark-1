sudo bash -c 'n=0; for f in /run/fc/*/serial.log; do grep -qE "Internal error: Oops|Unable to handle kernel|Kernel panic|rcu.*stall|soft lockup|hung_task" $f && { n=$((n+1)); echo "OOPS: $f"; grep -m3 -E "Oops|Unable to handle|panic|stall|lockup|pc :|Comm:" $f | head -4; }; done; echo "guests with kernel errors: $n of $(ls /run/fc/*/serial.log | wc -l)"' | head -40
# probe each live sandbox's daemon with a 5 s exec via the proxy
K=$(grep -oP '^VERA_RLP_API_KEY=\K.*' /home/daytona/arm64-benchmark-1/.env | tr -d '"')
ids=$(sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "select id from vms where status='running'")
echo "running rows: $(echo "$ids" | wc -l)"
for id in $ids; do
  code=$(curl -s -o /dev/null -w "%{http_code}" -m 8 -X POST -H "Authorization: Bearer $K" -H "Content-Type: application/json" -d '{"command":"echo ok","timeout":5}' http://127.0.0.1:9000/toolbox/$id/process/execute)
  echo "$code $id"
done | awk '{print $1}' | sort | uniq -c
