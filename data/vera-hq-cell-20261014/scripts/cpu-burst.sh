#!/bin/bash
# One pinned (socket 0) 1k burst with 0.5 s CPU accounting: socket-0 busy %, cgroup usage split
# (rlp.slice/vms = firecracker + guests, rlp-runner.service, rlp.slice total), mean socket-0 clock.
set -u
BD=/home/daytona/arm64-benchmark-1; API=http://127.0.0.1:8088; SL=/sys/fs/cgroup/rlp.slice
OUT=/mnt/data/bench/cpu-burst-$(date -u +%Y%m%d_%H%M%S)-${TAG:-x}; sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
K=$(sudo cat /etc/rlp/bench-api-key)
say() { echo "$(date -u +%T) $*" | tee -a $OUT/log; }
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
clean() { local i; for i in $(seq 1 60); do
    for id in $(PG "select id from vms where status not in ('deleted','failed','lost')"); do curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer $K" $API/vms/$id & done; wait
    [ "$(pgrep -c firecracker)" = 0 ] && return 0; sleep 5; done; }
pin() { echo "$1" | sudo tee $SL/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/cpuset.mems >/dev/null
  echo "$1" | sudo tee $SL/vms/cpuset.cpus >/dev/null; echo "$2" | sudo tee $SL/vms/cpuset.mems >/dev/null; }
HPN_ORIG=$(cat /sys/module/kvm/parameters/halt_poll_ns)
trap 'rc=$?; pin 0-351 0-1; echo $HPN_ORIG | sudo tee /sys/module/kvm/parameters/halt_poll_ns >/dev/null; say "SCRIPT EXIT rc=$rc (unpinned, halt_poll_ns=$(cat /sys/module/kvm/parameters/halt_poll_ns))"' EXIT
fleet() { ( cd $BD && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 RLP_HTTP_MAX_CONNECTIONS=1024 \
      RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0 && set -a && . ./.env && set +a && ulimit -n 1048576 && \
    MPFLEET_IMAGE=${IMG:-dtgraviet/vera-agent-benchmark:v3} timeout 600 uv run python mpfleet.py --procs 16 --count $1 --output $2 ) > $2.log 2>&1; tail -1 $2 | cut -c1-230; }
RUNCG=$(dirname $(grep -oP '0::\K.*' /proc/$(pgrep -nx rlp-runner)/cgroup)); RUNCG=/sys/fs/cgroup$(grep -oP '0::\K.*' /proc/$(pgrep -nx rlp-runner)/cgroup)
clean; if [ "${PLACE:-PIN}" = PIN ]; then pin 0-87,176-263 0; else pin 0-351 0-1; fi; sleep 5
say "image=${IMG:-dtgraviet/vera-agent-benchmark:v3} place=${PLACE:-PIN}"
[ -n "${HPN:-}" ] && echo $HPN | sudo tee /sys/module/kvm/parameters/halt_poll_ns >/dev/null
say "halt_poll_ns=$(cat /sys/module/kvm/parameters/halt_poll_ns) (orig $HPN_ORIG)"
say "pinned: slice=$(cat $SL/cpuset.cpus.effective) runner_cg=$RUNCG"
say "warm: $(fleet 10 $OUT/warm.jsonl)"; clean; say "warm2: $(fleet 10 $OUT/warm2.jsonl)"; clean
for w in $(seq 1 30); do sudo /usr/local/bin/bench-preflight $OUT/pf >/dev/null && break; sleep 10; done
grep -q "PREFLIGHT PASS" $OUT/pf/preflight.txt && say "preflight PASS" || say "preflight: $(grep FAIL $OUT/pf/preflight.txt | tr '\n' ' ')"
# sampler (runs on socket 1)
sudo taskset -c 300 python3 - $OUT/cpu.tsv $SL "$RUNCG" <<'PY' &
import sys,time,glob
out,sl,runcg=sys.argv[1:4]
S0=set(list(range(0,88))+list(range(176,264)))
def stat():
    busy=tot=0
    for l in open("/proc/stat"):
        if l.startswith("cpu") and l[3].isdigit():
            f=l.split(); c=int(f[0][3:])
            if c in S0:
                v=list(map(int,f[1:9])); idle=v[3]+v[4]; t=sum(v); busy+=t-idle; tot+=t
    return busy,tot
def us(p):
    try:
        for l in open(p+"/cpu.stat"):
            if l.startswith("usage_usec"): return int(l.split()[1])
    except Exception: return 0
    return 0
def freq():
    xs=[]
    for c in list(S0)[::8]:
        try: xs.append(int(open(f"/sys/devices/system/cpu/cpu{c}/cpufreq/scaling_cur_freq").read()))
        except Exception: pass
    return sum(xs)/len(xs)/1e6 if xs else 0
with open(out,"w") as fh:
    fh.write("t\ts0_busy_pct\tvms_cores\trunner_cores\tslice_cores\tghz\n")
    b0,t0=stat(); v0,r0,s0=us(sl+"/vms"),us(runcg),us(sl); T0=time.time(); tp=T0
    for _ in range(80):
        time.sleep(0.5)
        b,t=stat(); v,r,s=us(sl+"/vms"),us(runcg),us(sl); now=time.time(); dt=now-tp
        fh.write(f"{now-T0:.1f}\t{100*(b-b0)/max(1,t-t0):.1f}\t{(v-v0)/1e6/dt:.1f}\t{(r-r0)/1e6/dt:.1f}\t{(s-s0)/1e6/dt:.1f}\t{freq():.2f}\n"); fh.flush()
        b0,t0,v0,r0,s0,tp=b,t,v,r,s,now
PY
SP=$!; sleep 2
if [ "${PLACE:-PIN}" = PIN ]; then CL=88-175,264-351; else CL=0-351; fi
say "burst: $(IMG=${IMG:-} taskset -c $CL bash -c "$(declare -f fleet); BD=$BD; fleet 1000 $OUT/burst.jsonl")"
wait $SP; sudo chown $(id -u):$(id -g) $OUT/cpu.tsv
clean; say "DONE -> $OUT"
