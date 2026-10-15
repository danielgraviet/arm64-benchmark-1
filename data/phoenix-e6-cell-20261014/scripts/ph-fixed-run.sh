#!/bin/bash
# phoenix-e6 (Turin) with ALL create-path fixes on: #3260 initdisk nofsync, #3261 cgroup pool,
# #3265 permanent guest neigh, #3269 API listen backlog — plus the earlier set (sudo storm,
# FC_SOCK_WAIT, EROFS-4k). Idle image and agent image, 1k and 2k, 16-process client.
# Baselines to beat (same host, same client, fixes OFF, 2026-10-14):
#   idle  1k 7.95 / 7.96 s   2k 23.22 s
#   agent 1k 7.90 / 8.01 / 7.97 s   2k 22.30 / 21.94 s
set -u
exec 9>/tmp/ph-fixed.lock; flock -n 9 || { echo "another run holds the lock"; exit 1; }
BD=/home/ubuntu/arm64-benchmark-1; API=http://127.0.0.1:8088
OUT=/mnt/data/bench/fixed-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(sudo cat /etc/rlp/bench-api-key)
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
clean() { local i; for i in $(seq 1 200); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost') limit 4000"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id; done
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done
  say "  WARN killing $(pgrep -c firecracker) orphans"; sudo pkill -x firecracker; sleep 10; sudo rm -rf /run/fc/* 2>/dev/null
  PG "update vms set status='deleted' where status not in ('deleted','failed','lost')" >/dev/null; }
ovf() { awk '/ListenOverflows/{getline; print $NF}' /proc/net/netstat 2>/dev/null || echo 0; }
# $1 count  $2 image  $3 tag
lvl() {
  local n=$1 img=$2 tag=$3
  local f=$OUT/$tag-$n.jsonl
  clean; sleep 3
  sudo /usr/local/bin/bench-preflight $OUT/pf-$tag-$n >/dev/null || say "  (preflight: $(grep FAIL $OUT/pf-$tag-$n/preflight.txt | awk '{print $1}' | tr '\n' ' '))"
  local o0=$(ovf) t0=$(date -u +%s)
  ( cd $BD && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 MPFLEET_IMAGE="$img" MPFLEET_DISK=0.0625 && set -a && . ./.env && set +a && ulimit -n 1048576 && \
    timeout 900 uv run python mpfleet.py --target phoenix-e6 --count $n --procs 16 --timeout 300 --probe-timeout 120 --output $f ) > $f.log 2>&1
  local t1=$(date -u +%s) o1=$(ovf)
  sudo journalctl -u rlp-runner --no-pager -o cat --since "@$t0" --until "@$((t1+5))" > $f.journal 2>/dev/null
  local s=$(grep -o '"ok": [0-9]*, "failed": [0-9]*, "ready_wall_s": [0-9.]*' $f.log | tail -1)
  [ -n "$s" ] || s="NO SUMMARY: $(tail -2 $f.log | tr '\n' ' ' | cut -c1-140)"
  say "$tag n=$n $s listen_overflows=+$((o1-o0)) socktmo=$(grep -c 'fc.sock not accepting' $f.journal) cordons=$(grep -c 'self-cordon entered' $f.journal)"
  python3 - $f <<'PY' | sed 's/^/     /' | tee -a $OUT/log
import json,sys,statistics as st
rows=[json.loads(l) for l in open(sys.argv[1])]
sb=[r for r in rows if r.get("type")=="sandbox" and r.get("status")=="ok"]
if sb:
    q=lambda a,p:(sorted(a))[min(len(a)-1,int(p*len(a)))]
    po=[r["post_s"] for r in sb]; w=[r["wait_s"] for r in sb]; pr=[r.get("probe_s",0) for r in sb]
    t0=min(r["t_start"] for r in sb)
    print(f"post p50={st.median(po):.2f}s p90={q(po,.9):.2f}s | wait p50={st.median(w):.2f}s p90={q(w,.9):.2f}s | probe p50={st.median(pr)*1000:.0f}ms | all-running {max(r['t_start']+r['create_s'] for r in sb)-t0:.2f}s")
PY
  python3 - $f.journal <<'PY' | sed 's/^/     /' | tee -a $OUT/log
import re,sys,statistics as st
keys=["total_ms","clone_ms","scratch_cp_ms","fc_start_ms","load_ms","toolbox_wait_ms"]
v={k:[] for k in keys}
for l in open(sys.argv[1],errors="ignore"):
    if "boot-phases" not in l: continue
    for k in keys:
        m=re.search(rf"\b{k}=(\d+)",l)
        if m: v[k].append(int(m.group(1)))
if v["total_ms"]:
    q=lambda a,p:(sorted(a))[min(len(a)-1,int(p*len(a)))]
    print("runner per-clone ms: " + "  ".join(f"{k.replace('_ms','')} p50={st.median(x):.0f}/p90={q(x,.9):.0f}" for k,x in v.items() if x))
PY
}
say "=== fixes ON: $(sudo grep -hE '^RLP_(INITDISK_MODE|CGROUP_POOL|NEIGH_PERMANENT)=' /etc/rlp/runner.env | tr '\n' ' ') $(sudo grep -h '^RLP_API_LISTEN_BACKLOG=' /etc/rlp/api.env)"
say "    runner sha $(sha256sum /usr/local/bin/rlp-runner | cut -c1-12)  api sha $(sha256sum /opt/rlp/rlp-api | cut -c1-12)"
for r in 1 2; do lvl 1000 alpine:3.20 idle-r$r; done
lvl 2000 alpine:3.20 idle2k-r1
lvl 2000 alpine:3.20 idle2k-r2
for r in 1 2; do lvl 1000 dtgraviet/vera-agent-benchmark:v3 agent-r$r; done
lvl 2000 dtgraviet/vera-agent-benchmark:v3 agent2k-r1
clean
say "DONE -> $OUT"
