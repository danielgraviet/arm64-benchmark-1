#!/bin/bash
# usage: steps-dbexport.sh <run_dir>   -> <run_dir>/db.csv for the vm ids in client.jsonl
OUT=$1
IDS=$(python3 -c "import json,sys;print(','.join(json.loads(l)['vm_id'] for l in open(sys.argv[1]) if '\"vm_id\"' in l))" $OUT/client.jsonl)
sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -q -f - > $OUT/db.csv 2> $OUT/db.err <<SQL
copy (select v.id, extract(epoch from v.created_at)*1e6 as created_us, extract(epoch from v.started_at)*1e6 as started_us,
  (select extract(epoch from min(a.created_at))*1e6 from audit_logs a where a.target_id = v.id::text and a.action='create') as audit_us,
  (select max(j.stream_seq) from jobs j where j.vm_id = v.id and j.kind = 'vm.create') as stream_seq
  from vms v where v.id = any(string_to_array('$IDS', ',')::uuid[])) to stdout with csv header;
SQL
echo "db rows=$(($(wc -l < $OUT/db.csv)-1)) err=$(head -c 200 $OUT/db.err)"
