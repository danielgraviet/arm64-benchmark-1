# common.sh - host profiles + helpers shared by power-ladder.sh and mem-ladder.sh. Source it; set HOSTP first.
case ${HOSTP:?vera|phoenix|epyc9575|graviton5} in
  vera)      T=vera;       BD=${BD:-/home/daytona/arm64-benchmark-1}; ALL=0-351 ;;
  phoenix)   T=phoenix-e6; BD=${BD:-/home/ubuntu/arm64-benchmark-1};  ALL=0-383 ;;
  epyc9575)  T=epyc9575;   BD=${BD:-/home/ubuntu/arm64-benchmark-1};  ALL=0-127 ;;
  graviton5) T=graviton5;  BD=${BD:-/home/ubuntu/arm64-benchmark-1};  ALL=0-191 ;;
  *) echo "bad HOSTP"; exit 2 ;;
esac
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
API=http://127.0.0.1:8088; SL=/sys/fs/cgroup/rlp.slice
# API key: the harness .env key works everywhere; /etc/rlp/bench-api-key is stale on the 9575F.
K=${BENCH_KEY:-$(grep -hoP '^RLP_API_KEY=\K.*' $BD/.env 2>/dev/null | tr -d '"' | head -1)}
[ -n "$K" ] || K=$(sudo cat /etc/rlp/bench-api-key)
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
PG() { sudo docker exec -i rlp-postgres psql -U rlp -d rlplatform -tAc "$1" 2>/dev/null \
    || sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
clean() { local i; for i in $(seq 1 120); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost') limit 4000"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id & done; wait
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done
  say "WARN $(pgrep -c firecracker) firecrackers left after clean"; }
busy() { pgrep -f 'main\.py --benchmark|mpfleet\.py|memfleet\.py|rlp_light_create_fleet|gapfill\.sh' | grep -vx $$ | grep -q . || [ "$(pgrep -c firecracker)" != 0 ]; }
wait_idle() { local quiet=0; while [ $quiet -lt 3 ]; do if busy; then quiet=0; else quiet=$((quiet+1)); fi; sleep 60; done; }
gate() { local w; for w in $(seq 1 60); do sudo /usr/local/bin/bench-preflight $1 >/dev/null && return 0; sleep 10; done
  say "PREFLIGHT FAIL $1: $(grep FAIL $1/preflight.txt | tr '\n' ' ')"; return 1; }
PY=$BD/.venv/bin/python   # the harness venv directly: no uv/HOME dependence (the 9575F is driven as root)
envc() { cd $BD && export PATH=/usr/local/bin:$PATH PYTHONUNBUFFERED=1 && set -a && . ./.env && set +a && ulimit -n 1048576
  [ $HOSTP = vera ] && export RLP_API_URL=$API RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox VERA_RLP_API_URL=$API VERA_RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox VERA_RLP_TARGET=vera; true; }
sampler() { sudo python3 $HERE/power-sampler.py "$1" "${2:-}" >/dev/null 2>&1 & echo $!; }
stopsamp() { sudo kill $1 2>/dev/null; sudo pkill -f "power-sampler.py $2" 2>/dev/null; true; }
record_state() { # host state that must travel with the result
  { echo "host=$HOSTP target=$T kernel=$(uname -r) page=$(getconf PAGESIZE) nproc=$(nproc)"
    echo "runner_sha=$(sha256sum /usr/local/bin/rlp-runner | cut -c1-12) api_sha=$(sudo sha256sum /proc/$(pgrep -nx rlp-api)/exe | cut -c1-12)"
    echo "slice_cpus=$(cat $SL/cpuset.cpus.effective 2>/dev/null) slice_mems=$(cat $SL/cpuset.mems.effective 2>/dev/null)"
    sudo cat /proc/$(pgrep -nx rlp-runner)/environ | tr '\0' '\n' | grep -E '^RLP_(INITDISK_MODE|CGROUP_POOL|NEIGH_PERMANENT|VM_MAXACK|VM_CONCURRENCY|MAX_LIVE_VMS|NETNS_POOL|BURST_MAX_CPU|BURST_MAX_MEM_MIB|BALLOON|FC_SOCK_WAIT_MS)='
    sudo cat /proc/$(pgrep -nx rlp-api)/environ | tr '\0' '\n' | grep -E '^RLP_(API_LISTEN_BACKLOG|MIN_CPU|MIN_MEM_MIB|MIN_SCRATCH_MIB)='
    for g in /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver; do [ -e $g ] && echo "$(basename $g)=$(cat $g)"; done
    cat /proc/cmdline; } > $OUT/host-state.txt 2>&1; }
