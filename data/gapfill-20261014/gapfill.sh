#!/bin/bash
# gapfill.sh — fills the missing cells of the Vera / Turin (phoenix-e6) / Graviton5 comparison with ONE uniform method.
#   HOSTP=vera|phoenix|graviton5   PHASES="S T" (default per host)
#   S = startup matrix: {UNPIN, HALF} x {alpine:3.20 idle, agent image} x {1k x3, 2k x2}; mpfleet 16 procs, client unpinned
#   C = idle-density ceiling (alpine, UNPIN, 16 procs): 3000 4000 5000 6000, stop at first level that does not land fully.
#       Needs the raised caps from capacity.sh (MAX_LIVE_VMS>=8000, NETNS_POOL>=6200, /18 subnet) — skipped otherwise.
#   T = published dense throughput ladder (agent n=45 seed 42 -E 8 hold-then-exec, cpu .025/max 1, mem .0625/max 4, disk 16 MiB)
#       UNPIN on the full level set, HALF on the short set. Power (where the host exposes it) + clock sampled every 2 s.
# HALF = one socket (Vera, Turin) / one NUMA node (Graviton5). Only rlp.slice (+vms) is pinned; API, DB, NATS, client float.
# Waits for the host to be idle (no other bench client, no firecracker) before starting; refuses to double-start.
set -u
HOSTP=${HOSTP:?vera|phoenix|graviton5}
case $HOSTP in
  vera)      T=vera;       ALL=0-351; HALF=0-87,176-263; DEF_PHASES="S T"; T_ARMS=${T_ARMS:-"UNPIN HALF"} ;;
  phoenix)   T=phoenix-e6; ALL=0-383; HALF=0-95,192-287; DEF_PHASES="S T"; T_ARMS=${T_ARMS:-"UNPIN HALF"} ;;
  graviton5) T=graviton5;  ALL=0-191; HALF=0-95;         DEF_PHASES="S";   T_ARMS=${T_ARMS:-""} ;;
  *) echo "bad HOSTP"; exit 2 ;;
esac
PHASES=${PHASES:-$DEF_PHASES}
LV_FULL=${LV_FULL:-"44 88 176 352 528 704 880 1056 1408 1760 2000"}; LV_SHORT=${LV_SHORT:-"44 88 176 352 704 1056 1408"}
AGENT=dtgraviet/vera-agent-benchmark:v3; IDLE=alpine:3.20
BD=$HOME/arm64-benchmark-1; API=http://127.0.0.1:8088; SL=/sys/fs/cgroup/rlp.slice
exec 9>/tmp/gapfill.lock; flock -n 9 || { echo "gapfill already running"; exit 1; }
OUT=/mnt/data/bench/gapfill-$HOSTP-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(sudo cat /etc/rlp/bench-api-key)
RES=$OUT/results.tsv; printf 'phase\tlayout\timage\tn_or_c\trep\tok\tfailed\twall_s\tp50_s\tp95_s\taccept_p50_s\ttput_s\tp50_dur_s\tpower_w\tghz\tsocktmo\tcordons\n' > $RES
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
busy() { pgrep -f 'main\.py --benchmark|mpfleet\.py|rlp_light_create_fleet|stepclient\.py|bench-startup' | grep -vx $$ | grep -q . || [ "$(pgrep -c firecracker)" != 0 ]; }
wait_idle() { local quiet=0; while [ $quiet -lt 5 ]; do if busy; then quiet=0; else quiet=$((quiet+1)); fi; sleep 60; done; }
clean() { local i; for i in $(seq 1 120); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id & done; wait
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done
  say "WARN $(pgrep -c firecracker) firecrackers left after clean"; }
pin() { grep -qw cpuset /sys/fs/cgroup/cgroup.subtree_control || echo +cpuset | sudo tee /sys/fs/cgroup/cgroup.subtree_control >/dev/null
  grep -qw cpuset $SL/cgroup.subtree_control || echo +cpuset | sudo tee $SL/cgroup.subtree_control >/dev/null
  echo "$1" | sudo tee $SL/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/cpuset.mems >/dev/null
  if [ -d $SL/vms ]; then grep -qw cpuset $SL/vms/cgroup.subtree_control || echo +cpuset | sudo tee $SL/vms/cgroup.subtree_control >/dev/null 2>&1
    echo "$1" | sudo tee $SL/vms/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/vms/cpuset.mems >/dev/null; fi; }
layout() { case $1 in UNPIN) pin $ALL 0-1 ;; HALF) pin $HALF 0 ;; esac; sleep 3
  local want=$([ $1 = UNPIN ] && echo $ALL || echo $HALF) got=$(cat $SL/cpuset.cpus.effective) rc=$(awk '/Cpus_allowed_list/{print $2}' /proc/$(pgrep -nx rlp-runner)/status)
  [ "$got" = "$want" ] && [ "$rc" = "$want" ] || { say "LAYOUT MISMATCH $1 slice=$got runner=$rc want=$want"; return 1; }
  say "layout $1: slice=$got mems=$(cat $SL/cpuset.mems.effective) runner=$rc api=$(awk '/Cpus_allowed_list/{print $2}' /proc/$(pgrep -nx rlp-api)/status)"; }
gate() { local w; for w in $(seq 1 60); do sudo /usr/local/bin/bench-preflight $1 >/dev/null && return 0; sleep 10; done
  say "PREFLIGHT FAIL $1: $(grep FAIL $1/preflight.txt | tr '\n' ' ')"; return 1; }
envc() { cd $BD && export PATH=$HOME/.local/bin:/usr/local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 && set -a && . ./.env && set +a && ulimit -n 1048576
  [ $HOSTP = vera ] && export RLP_API_URL=$API RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox VERA_RLP_API_URL=$API VERA_RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox VERA_RLP_TARGET=vera; true; }
mpf() { # $1 count $2 image $3 out
  ( envc; export RLP_HTTP_MAX_CONNECTIONS=1024 RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0 MPFLEET_IMAGE="$2"
    timeout 900 uv run python mpfleet.py --target $T --procs $(( $1 < 16 ? $1 : 16 )) --count $1 --timeout 300 --probe-timeout 120 --output $3 ) > $3.log 2>&1; }
jcount() { local J="sudo journalctl -u rlp-runner --no-pager -o cat --since @$1 --until @$(( $2 + 5 ))"; echo "$($J | grep -c 'not accepting') $($J | grep -c 'self-cordon entered')"; }
# sampler: t, power_w (Vera: AP Power socket0+1 hwmon; x86: RAPL package energy delta; else empty), mean GHz, fc count, #ladder summaries in $2
sampler() { sudo python3 $(dirname "$0")/gapfill-sampler.py "$1" "${2:-}" >/dev/null 2>&1 & echo $!; }
stopsamp() { sudo kill $1 2>/dev/null; sudo pkill -P $1 2>/dev/null; true; }

grep -q MPFLEET_IMAGE $BD/mpfleet.py || { echo "mpfleet.py lacks MPFLEET_IMAGE override — update it first" | tee -a $OUT/log; exit 1; }
say "gapfill host=$HOSTP target=$T phases=$PHASES t_arms='$T_ARMS' waiting for the host to be idle (5 quiet minutes)"
wait_idle
trap 'rc=$?; pin $ALL 0-1; say "SCRIPT EXIT rc=$rc (rlp.slice unpinned)"' EXIT
say "host idle; kernel=$(uname -r) page=$(getconf PAGESIZE) runner=$(sha256sum /usr/local/bin/rlp-runner | cut -c1-12) caps: $(sudo cat /proc/$(pgrep -nx rlp-runner)/environ | tr '\0' '\n' | grep -E '^RLP_(MAX_LIVE_VMS|NETNS_POOL|VM_CONCURRENCY|SUBNET_CIDR)=' | tr '\n' ' ')"

phaseS() {
  for lay in UNPIN HALF; do for img in $IDLE $AGENT; do
    local it=$([ $img = $IDLE ] && echo idle || echo agent) d=$OUT/S/$lay-$([ $img = $IDLE ] && echo idle || echo agent); mkdir -p $d
    clean; layout $lay || return 1; mpf 10 $img $d/warm.jsonl; clean
    for spec in 1000:1 1000:2 1000:3 2000:1 2000:2; do local n=${spec%:*} r=${spec#*:} f=$d/n${spec%:*}-r${spec#*:}.jsonl
      clean; gate $d/pf-$n-$r || return 1
      local sp=$(sampler $f.samp); local t0=$(date +%s); mpf $n $img $f; local t1=$(date +%s); stopsamp $sp
      read st sc < <(jcount $t0 $t1)
      local line=$(python3 - $f $f.samp <<'PY'
import json,sys,math
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
s=next((r for r in rows if r.get("type")=="summary"),{})
ok=[r for r in rows if r.get("type")=="sandbox" and r.get("status")=="ok"]
q=lambda a,x: sorted(a)[min(len(a)-1,int(x*len(a)))] if a else float("nan")
c=[r["create_s"] for r in ok]
pw=[float(l.split("\t")[1]) for l in open(sys.argv[2]) if l[:1].isdigit()]
pw=[p for p in pw if not math.isnan(p)]
print("\t".join(str(x) for x in [s.get("ok",0),s.get("failed","?"),f"{s.get('ready_wall_s',float('nan')):.2f}",f"{q(c,.5):.2f}",f"{q(c,.95):.2f}",f"{s.get('post_p50_s',float('nan')):.2f}","","",f"{max(pw):.0f}" if pw else "",""]))
PY
)
      printf 'S\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' $lay $it $n $r "$line" $st $sc >> $RES
      say "S $lay $it n=$n r$r $(echo "$line" | awk -F'\t' '{printf "ok=%s fail=%s wall=%s p50=%s p95=%s accept_p50=%s peak_w=%s",$1,$2,$3,$4,$5,$6,$9}') socktmo=$st cordons=$sc"
    done; done; done; clean; }

phaseC() {
  local cap=$(sudo cat /proc/$(pgrep -nx rlp-runner)/environ | tr '\0' '\n' | grep -oP '^RLP_MAX_LIVE_VMS=\K.*')
  [ "${cap:-0}" -ge 6000 ] || { say "C skipped: RLP_MAX_LIVE_VMS=${cap:-?} (run capacity.sh raise first)"; return 0; }
  local d=$OUT/C; mkdir -p $d; clean; layout UNPIN || return 1; mpf 10 $IDLE $d/warm.jsonl
  for n in ${C_LEVELS:-3000 4000 5000 6000}; do local f=$d/ceil-$n.jsonl
    clean; gate $d/pf-$n || return 1
    local sp=$(sampler $f.samp); local t0=$(date +%s); mpf $n $IDLE $f; local t1=$(date +%s); stopsamp $sp
    read st sc < <(jcount $t0 $t1)
    local ok=$(python3 -c "import json,sys; s=[json.loads(l) for l in open(sys.argv[1]) if '\"summary\"' in l]; print(s[-1]['ok'] if s else 0)" $f 2>/dev/null)
    local pk=$(awk -F'\t' '$1~/^[0-9]/{if($4>m)m=$4; if(mn==""||$6<mn)mn=$6}END{print m+0" "mn+0}' $f.samp)
    printf 'C\tUNPIN\tidle\t%s\t1\t%s\t%s\t%s\t\t\t\t\t\t\t\t%s\t%s\n' $n ${ok:-0} $(( n - ${ok:-0} )) "$(python3 -c "import json,sys; s=[json.loads(l) for l in open(sys.argv[1]) if '\"summary\"' in l]; print(round(s[-1]['ready_wall_s'],2) if s else '')" $f 2>/dev/null)" $st $sc >> $RES
    say "C n=$n ok=${ok:-0}/$n peak_fc/min_memavail_gib=$pk socktmo=$st cordons=$sc nocap=$(grep -c 'no matching capacity' $f.log)"
    [ "${ok:-0}" -lt "$n" ] && { say "C STOP: ceiling reached at $n"; break; }
  done; clean; }

phaseT() {
  for lay in $T_ARMS; do local d=$OUT/T; mkdir -p $d; local LV=$([ $lay = UNPIN ] && echo "$LV_FULL" || echo "$LV_SHORT")
    clean; layout $lay || return 1; gate $d/pf-$lay || return 1
    local sp=$(sampler $d/$lay.samp $d/$lay.jsonl) t0=$(date +%s)
    ( envc; export RLP_HTTP_MAX_CONNECTIONS=512 RLP_HOLD_CREATE_BATCH=512
      uv run main.py --benchmark agent --runner rlp --target $T --snapshot $AGENT --levels $LV --n 45 --seed 42 -E 8 --hold-then-exec \
        --rlp-cpu 0.025 --rlp-cpu-max 1 --rlp-memory 0.0625 --rlp-memory-max 4 --rlp-disk 0.015625 --output $d/$lay.jsonl ) > $d/$lay.log 2>&1
    local rc=$? t1=$(date +%s); stopsamp $sp
    read st sc < <(jcount $t0 $t1)
    say "T $lay exit=$rc $(( (t1-t0)/60 )) min socktmo=$st cordons=$sc"
    python3 - $d/$lay.jsonl $d/$lay.samp $lay $st $sc <<'PY' | tee -a $RES | while IFS=$'\t' read -r ph l i c r ok f w p50 p95 a tp pd pw g x y; do say "  T $l c=$c tput=$tp/s fail=$f p50_dur=${pd}s power=${pw}W ghz=$g"; done
import json,sys,math
jf,sf,lay,st,sc=sys.argv[1:6]
S=[json.loads(l) for l in open(jf) if '"summary"' in l]
smp=[l.rstrip("\n").split("\t") for l in open(sf) if l[:1].isdigit()]
smp=[(float(x[0]),float(x[1]),float(x[2]),int(x[3]),int(x[4])) for x in smp]
for k,s in enumerate(S):
    # level k ends when the (k+1)th summary appears; take the exec window before that
    ends=[t for t,p,g,fc,n in smp if n>=k+1]; tend=ends[0] if ends else None
    win=[(p,g) for t,p,g,fc,n in smp if tend and tend-s["exec_wall_s"]<=t<tend] if tend else []
    pw=[p for p,g in win if not math.isnan(p)]; gz=[g for p,g in win if not math.isnan(g)]
    print("\t".join(str(x) for x in ["T",lay,"agent",s["concurrency"],"",s["runs"]-s["failures"],s["failures"],s.get("exec_wall_s"),"","","",s["throughput_per_sec"],f"{s['p50_duration_ms']/1000:.2f}",f"{sum(pw)/len(pw):.0f}" if pw else "",f"{sum(gz)/len(gz):.2f}" if gz else "",st,sc]))
PY
  done; clean; }

for ph in $PHASES; do say "=== phase $ph"; phase$ph || say "phase $ph FAILED"; done
say "DONE -> $OUT"
