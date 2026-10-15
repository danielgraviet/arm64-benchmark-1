#!/bin/bash
# Harness benchmarks on HQ Vera with the four create-path fixes OFF vs ON (same binaries; flags only).
#   startup:    mpfleet.py --procs 16 --count 1000 (harness per-sandbox logic, SDK polling), alpine + agent image
#   throughput: published dense ladder (main.py agent bench, n=45, -E 8, hold-then-exec), levels 176 352 704
# Unpinned (whole machine). Order interleaved OFF/ON with drift-check repeats.
set -u
BD=/home/daytona/arm64-benchmark-1; API=http://127.0.0.1:8088
OUT=/mnt/data/bench/fixes-bench-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(grep -oP '^VERA_RLP_API_KEY=\K.*' $BD/.env | tr -d '"')
AGENT=dtgraviet/vera-agent-benchmark:v3; IDLE=alpine:3.20
ON_RUNNER="RLP_INITDISK_MODE=nofsync;RLP_CGROUP_POOL=1400;RLP_NEIGH_PERMANENT=1"; ON_API="RLP_API_LISTEN_BACKLOG=4096"
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
renv() { sudo cat /proc/$(pgrep -nx $1)/environ 2>/dev/null | tr '\0' '\n' | grep -oP "^$2=\K.*"; }
clean() { local i; for i in $(seq 1 90); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id & done; wait
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done; say "WARN $(pgrep -c firecracker) firecrackers left"; }
wfile() { if [ -z "$2" ]; then sudo rm -f $1; else printf '%s\n' "$2" | tr ';' '\n' | sudo tee $1 >/dev/null; fi; }
setflags() { # $1 on|off
  if [ $1 = on ]; then wfile /etc/rlp/arm-runner.env "$ON_RUNNER"; wfile /etc/rlp/arm-api.env "$ON_API"
  else wfile /etc/rlp/arm-runner.env ""; wfile /etc/rlp/arm-api.env ""; fi
  for u in runner api; do f=/etc/systemd/system/rlp-$u.service.d/zz-arm.conf
    if sudo test -s /etc/rlp/arm-$u.env; then printf '[Service]\nEnvironmentFile=/etc/rlp/arm-%s.env\n' $u | sudo tee $f >/dev/null; else sudo rm -f $f; fi; done
  clean
  sudo find /sys/fs/cgroup/rlp.slice/vms -maxdepth 1 -name 'vm-pool-*' -exec rmdir {} + 2>/dev/null
  sudo systemctl daemon-reload; sudo systemctl restart rlp-api; sleep 3; sudo systemctl restart rlp-runner
  for i in $(seq 1 120); do curl -fsS -m 2 $API/health >/dev/null 2>&1 && break; sleep 1; done
  local ok=0; for i in $(seq 1 180); do n=$(sudo ip netns list 2>/dev/null | wc -l)
    if [ "$n" -ge 1995 ]; then ok=$((ok+1)); [ $ok -ge 2 ] && break; else ok=0; fi; sleep 10; done
  sleep 5
  say "FLAGS $1: initdisk=$(renv rlp-runner RLP_INITDISK_MODE || echo copy) neigh=$(renv rlp-runner RLP_NEIGH_PERMANENT || echo -) cgpool=$(renv rlp-runner RLP_CGROUP_POOL || echo 0) backlog=$(ss -ltn 'sport = :8088' | awk 'NR==2{print $2+$3}') netns=$(sudo ip netns list | wc -l) cgpool_ready=$(sudo ls /sys/fs/cgroup/rlp.slice/vms | grep -c '^vm-pool-')"
  # template warm (image templates may be rebuilt after restart): 2 small waves per image
  for img in $IDLE $AGENT; do for w in 1 2; do fleet $img 10 $OUT/warm-$1-$(basename $img | tr ':/' '__')-$w.jsonl >/dev/null; clean; done; done
}
fleet() { # $1 image $2 count $3 out
  ( cd $BD && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 RLP_HTTP_MAX_CONNECTIONS=1024 RLP_HTTP_READ_TIMEOUT_S=120 \
      RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0 MPFLEET_IMAGE=$1 && set -a && . ./.env && set +a && \
    ulimit -n 1048576 && timeout 900 uv run python mpfleet.py --procs 16 --count $2 --output $3 ) > $3.log 2>&1
  python3 -c "import json,sys;s=[json.loads(l) for l in open(sys.argv[1])][-1];print('ok=%d failed=%d all_ready=%.2fs create_p50=%.2fs p95=%.2fs post_p50=%.2fs'%(s['ok'],s['failed'],s['ready_wall_s'],s['create_p50_s'],s['create_p95_s'],s['post_p50_s']))" $3 2>/dev/null || echo "no-summary"; }
startup() { # $1 flags  $2 image-label  $3 image  $4 rep
  clean; sleep 2
  for w in $(seq 1 30); do sudo /usr/local/bin/bench-preflight $OUT/pf-$1-$2-$4 >/dev/null 2>&1 && break; sleep 10; done
  local pf=$(grep -q 'PREFLIGHT PASS' $OUT/pf-$1-$2-$4/preflight.txt && echo PASS || echo "FAIL:$(grep FAIL $OUT/pf-$1-$2-$4/preflight.txt | awk '{print $1}' | tr '\n' ',')")
  local a=$(nstat -az TcpExtListenOverflows | tail -1 | awk '{print $2}')
  local r=$(fleet $3 1000 $OUT/startup-$1-$2-$4.jsonl)
  local b=$(nstat -az TcpExtListenOverflows | tail -1 | awk '{print $2}')
  say "STARTUP flags=$1 image=$2 rep=$4 $r overflows=$((b-a)) preflight=$pf"
}
tput() { # $1 flags
  clean
  for w in $(seq 1 30); do sudo /usr/local/bin/bench-preflight $OUT/pf-$1-tput >/dev/null 2>&1 && break; sleep 10; done
  ( cd $BD && export PATH=$HOME/.local/bin:/usr/local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 && set -a && . ./.env && set +a && \
    export RLP_API_URL=$API RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox VERA_RLP_API_URL=$API \
           VERA_RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox VERA_RLP_TARGET=vera RLP_HTTP_MAX_CONNECTIONS=512 RLP_HOLD_CREATE_BATCH=512 RLP_HTTP_READ_TIMEOUT_S=120 && \
    ulimit -n 1048576 && \
    timeout 3600 uv run main.py --benchmark agent --runner rlp --target vera --snapshot $AGENT \
      --levels 176 352 704 --n 45 --seed 42 -E 8 --hold-then-exec --rlp-cpu 0.025 --rlp-cpu-max 1 \
      --rlp-memory 0.0625 --rlp-memory-max 4 --rlp-disk 0.015625 --output $OUT/tput-$1.jsonl ) > $OUT/tput-$1.log 2>&1
  python3 - $OUT/tput-$1.jsonl <<'PY' | while read l; do say "TPUT flags=$1 $l"; done
import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r.get("type")=="summary":
        print(f"c={r['concurrency']} runs={r['runs']} failures={r['failures']} tput={r['throughput_per_sec']}/s p50={r['p50_ms']/1000:.1f}s p99={r['p99_ms']/1000:.1f}s")
PY
}
trap 'rc=$?; setflags off >/dev/null 2>&1; clean; say "SCRIPT EXIT rc=$rc (flags restored OFF)"' EXIT
say "host: $(uname -r) nproc=$(nproc) runner=$(sha256sum /usr/local/bin/rlp-runner | cut -c1-12) api=$(sha256sum /opt/rlp/rlp-api | cut -c1-12) slice=$(cat /sys/fs/cgroup/rlp.slice/cpuset.cpus.effective)"
for flags in off on; do
  setflags $flags
  for r in 1 2; do startup $flags idle $IDLE $r; startup $flags agent $AGENT $r; done
  tput $flags
done
for flags in off on; do   # drift check
  setflags $flags
  startup $flags idle $IDLE 3; startup $flags agent $AGENT 3
done
say "DONE -> $OUT"
