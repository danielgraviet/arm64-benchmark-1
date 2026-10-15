#!/bin/bash
# A/B: API Postgres pool (RLP_DB_MAX_CONNECTIONS 64 default vs 256), 1k idle-image burst per arm, interleaved.
S=/home/daytona/steps; OUT=/mnt/data/bench/api-ab-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
renv() { sudo cat /proc/$(pgrep -nx rlp-api)/environ | tr '\0' '\n' | grep -oP "^$1=\K.*"; }
setpool() { if [ $1 = default ]; then sudo rm -f /etc/systemd/system/rlp-api.service.d/zz-arm.conf /etc/rlp/arm-api.env
  else echo "RLP_DB_MAX_CONNECTIONS=$1" | sudo tee /etc/rlp/arm-api.env >/dev/null
       printf '[Service]\nEnvironmentFile=/etc/rlp/arm-api.env\n' | sudo tee /etc/systemd/system/rlp-api.service.d/zz-arm.conf >/dev/null; fi
  sudo systemctl daemon-reload; sudo systemctl restart rlp-api
  for i in $(seq 1 60); do curl -fsS -m 2 http://127.0.0.1:8088/health >/dev/null 2>&1 && break; sleep 1; done; sleep 10
  # warm the pool: 3 waves of 300 concurrent authenticated reads (each opens/uses a DB connection)
  K=$(grep -oP '^VERA_RLP_API_KEY=\K.*' /home/daytona/arm64-benchmark-1/.env | tr -d '"')
  for w in 1 2 3; do seq 300 | xargs -P 300 -I{} curl -s -o /dev/null -m 10 -H "Authorization: Bearer $K" "http://127.0.0.1:8088/vms?limit=1"; done
  echo "  pool warm: pg conns=$(sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "select count(*) from pg_stat_activity where datname='rlplatform'")"; sleep 5; }
trap 'setpool default; echo "restored: RLP_DB_MAX_CONNECTIONS=$(renv RLP_DB_MAX_CONNECTIONS || true) (unset = default 64)"' EXIT
sampler() { # pg connection states + API CPU, 0.25 s, 40 s
  local P=$(pgrep -nx rlp-api) hz=$(getconf CLK_TCK) prev=0
  for i in $(seq 1 160); do
    c=$(sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "select coalesce(sum((state='active')::int),0)||' '||coalesce(sum((state='idle')::int),0)||' '||coalesce(sum((wait_event_type='Lock')::int),0) from pg_stat_activity where datname='rlplatform' and pid<>pg_backend_pid()" 2>/dev/null)
    cpu=$(awk '{print $14+$15}' /proc/$P/stat)
    echo "$(date +%s.%N) $c $cpu"; sleep 0.25; done > $1; }
summ() { python3 - $1 <<'PY'
import sys
r=[l.split() for l in open(sys.argv[1]) if len(l.split())==5]
act=[int(x[1]) for x in r]; lock=[int(x[3]) for x in r]
cpu=[(float(b[0]),int(b[4])) for b in r]; hz=100
rate=[(c2-c1)/hz/(t2-t1) for (t1,c1),(t2,c2) in zip(cpu,cpu[1:]) if t2>t1]
print(f"pg active conns peak={max(act)} (samples>=60: {sum(1 for a in act if a>=60)}) lock-waits peak={max(lock)} | API CPU peak={max(rate):.1f} cores")
PY
}
for arm in default 256 default 256; do
  setpool $arm; echo "== pool=$arm (env: $(renv RLP_DB_MAX_CONNECTIONS || echo unset))"
  F=$OUT/pg-$arm-$(date +%s).txt; sampler $F & SP=$!
  bash $S/steps-run.sh burst-alpine-pool$arm burst 1000 alpine:3.20 16 > $OUT/steps-$arm-$$.out 2>&1
  kill $SP 2>/dev/null; wait $SP 2>/dev/null
  grep -E "^1 |^2 |^3 |^4 |POST -> client sees running" $OUT/steps-$arm-$$.out; echo "  $(summ $F)"
  mv $OUT/steps-$arm-$$.out $OUT/steps-$arm-$(date +%s).out
done
