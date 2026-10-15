#!/bin/bash
# Does scaling the toolbox proxy change create-ready at high concurrency?
#   P1: 1 proxy direct on :9000   L1: haproxy :9000 -> 1 proxy   L4: haproxy :9000 -> 4 proxies
# Layout: runner+sandboxes pinned to socket 0 (the fast/published layout); control plane + proxies unpinned.
set -u
BD=/home/daytona/arm64-benchmark-1; API=http://127.0.0.1:8088
OUT=/mnt/data/bench/proxy-scale-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(sudo cat /etc/rlp/bench-api-key); SL=/sys/fs/cgroup/rlp.slice
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
clean() { local i; for i in $(seq 1 60); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id; done
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done
  say "WARN killing $(pgrep -c firecracker) orphans"; sudo pkill -x firecracker; sleep 5; sudo rm -rf /run/fc/* 2>/dev/null
  PG "update vms set status='deleted' where status not in ('deleted','failed','lost')" >/dev/null; }
pin() { echo "$1" | sudo tee $SL/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/cpuset.mems >/dev/null
  [ -d $SL/vms ] && { echo "$1" | sudo tee $SL/vms/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/vms/cpuset.mems >/dev/null; }; }
fleet() { ( cd $BD && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 RLP_HTTP_MAX_CONNECTIONS=$3 \
      RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0 && set -a && . ./.env && set +a && ulimit -n 1048576 && \
    timeout 600 uv run python scripts/rlp_light_create_fleet.py --target vera --count $1 --workers $1 \
      --image dtgraviet/vera-agent-benchmark:v3 --cpu 0.025 --memory 0.0625 --disk 1.0 --probe 'echo ready' --output $2 ) > $2.log 2>&1; }
stats() { python3 - $1 <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
sb=[r for r in rows if r.get("type")=="sandbox"]; ok=[r for r in sb if r.get("status")=="ok"]
s=next((r for r in rows if r.get("type")=="summary"),{})
q=lambda a,x: a[min(len(a)-1,int(x*len(a)))] if a else float('nan')
c=sorted(r["create_s"] for r in ok); p=sorted((r.get("probe_s") or 0)*1000 for r in ok); a=sorted(r.get("post_s",0) for r in ok)
err={}
for r in sb:
    if r.get("status")!="ok": e=(r.get("error") or "")[:60]; err[e]=err.get(e,0)+1
print(f"ok={len(ok)}/{len(sb)} wall={s.get('ready_wall_s',float('nan')):.2f} p50={q(c,.5):.2f} p95={q(c,.95):.2f} accept50={q(a,.5):.2f} | probe_ms p50={q(p,.5):.0f} p99={q(p,.99):.0f} max={max(p) if p else 0:.0f} | errors={err or 'none'}")
PY
}
cpu_s() { local t=0 p; for p in $(pgrep -x rlp-proxy) $(pgrep -x haproxy); do t=$((t + $(awk '{print $14+$15}' /proc/$p/stat 2>/dev/null || echo 0))); done; echo $t; }
# ---------- proxy topologies ----------
setup_units() {
  sed -e 's#^EnvironmentFile=/etc/rlp/proxy.env#EnvironmentFile=/etc/rlp/proxy.env\nEnvironmentFile=/etc/rlp/proxy-%i.env#' \
      -e 's#^Description=.*#Description=rl-platform toolbox proxy instance %i (bench scale-out)#' \
      /etc/systemd/system/rlp-proxy.service | sudo tee /etc/systemd/system/rlp-proxy@.service >/dev/null
  for i in 1 2 3 4; do printf 'RLP_PROXY_LISTEN=127.0.0.1:910%s\nRLP_SSH_LISTEN=127.0.0.1:223%s\n' $i $i | sudo tee /etc/rlp/proxy-$i.env >/dev/null; done
  sudo systemctl daemon-reload; }
lb_cfg() { # $1 = number of backends
  { printf 'global\n  maxconn 200000\n  nbthread 16\ndefaults\n  mode http\n  timeout connect 5s\n  timeout client 900s\n  timeout server 900s\n  option http-keep-alive\n'
    printf 'frontend fe\n  bind 0.0.0.0:9000\n  maxconn 200000\n  default_backend be\nbackend be\n  balance roundrobin\n'
    for i in $(seq 1 $1); do printf '  server p%s 127.0.0.1:910%s maxconn 50000\n' $i $i; done; } | sudo tee /etc/rlp/haproxy.cfg >/dev/null; }
topo() { # P1 | L1 | L4
  sudo docker rm -f rlp-lb >/dev/null 2>&1; for i in 1 2 3 4; do sudo systemctl stop rlp-proxy@$i 2>/dev/null; done; sudo systemctl stop rlp-proxy
  case $1 in
    P1) sudo systemctl start rlp-proxy ;;
    L1|L4) n=${1#L}; for i in $(seq 1 $n); do sudo systemctl start rlp-proxy@$i; done; lb_cfg $n
           sudo docker run -d --name rlp-lb --network host --ulimit nofile=1048576:1048576 -v /etc/rlp/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro haproxy:3.0 >/dev/null ;;
  esac
  sleep 6
  say "TOPO $1: :9000 -> $(ss -ltnp 2>/dev/null | awk '$4 ~ /:9000$/' | grep -oE '"[a-z-]+"' | sort -u | tr '\n' ' ') proxies=$(pgrep -cx rlp-proxy) listening=$(ss -ltn | grep -cE '127.0.0.1:910[1-4] ') lb=$(sudo docker ps -q -f name=rlp-lb | wc -l)"
  curl -s -o /dev/null -m 5 -w "  :9000 answers http %{http_code}\n" http://127.0.0.1:9000/ | tee -a $OUT/log; }
run_arm() { local name=$1 arm=$OUT/$1; mkdir -p $arm; clean; topo $name
  fleet 10 $arm/warm.jsonl 1024; say "  warm: $(stats $arm/warm.jsonl)"
  for spec in "1000 1 1024" "1000 2 1024" "1000 3 1024" "2000 1 4096" "2000 2 4096"; do set -- $spec; local n=$1 r=$2 pool=$3
    clean; local ok=0; for w in $(seq 1 30); do sudo /usr/local/bin/bench-preflight $arm/pf-$n-$r >/dev/null && { ok=1; break; }; sleep 10; done
    [ $ok = 1 ] || { say "  PREFLIGHT FAIL $n rep$r: $(grep FAIL $arm/pf-$n-$r/preflight.txt | tr '\n' ' ')"; continue; }
    local c0=$(cpu_s); fleet $n $arm/n$n-rep$r.jsonl $pool; local c1=$(cpu_s)
    say "  $name n=$n rep$r $(stats $arm/n$n-rep$r.jsonl) proxy+lb_cpu_s=$(( (c1-c0)/$(getconf CLK_TCK) ))"
  done; }
restore() { sudo docker rm -f rlp-lb >/dev/null 2>&1; for i in 1 2 3 4; do sudo systemctl stop rlp-proxy@$i 2>/dev/null; done
  sudo systemctl start rlp-proxy; pin 0-351 0-1; clean
  say "restored: rlp-proxy=$(systemctl is-active rlp-proxy) on :9000, slice=$(cat $SL/cpuset.cpus.effective), lb gone=$([ -z "$(sudo docker ps -q -f name=rlp-lb)" ] && echo yes)"; }
trap restore EXIT
setup_units; pin 0-87,176-263 0
say "layout: runner+sandboxes socket 0 ($(cat $SL/cpuset.cpus.effective)), control plane + proxies unpinned"
run_arm P1; run_arm L1; run_arm L4
say "DONE -> $OUT"
