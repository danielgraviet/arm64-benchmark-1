#!/bin/bash
# One measurement arm with the patched binaries.
#   arm.sh <tag> <burst|seq> <count> "<RUNNER_ENV lines, ;-separated>" "<API_ENV lines>"
# Writes the arm env as a SECOND EnvironmentFile (beats runner.env/api.env), restarts, waits for the
# netns pool, runs steps-run.sh, prints the key rows. Empty env strings = stock behaviour (control).
set -u
S=/home/daytona/steps
TAG=$1; MODE=$2; COUNT=$3; RENV=${4:-}; AENV=${5:-}
renv() { sudo cat /proc/$(pgrep -nx $1)/environ 2>/dev/null | tr '\0' '\n' | grep -oP "^$2=\K.*"; }
w() { # $1 file  $2 ;-separated lines
  if [ -z "$2" ]; then sudo rm -f $1; else printf '%s\n' "$2" | tr ';' '\n' | sudo tee $1 >/dev/null; fi; }
w /etc/rlp/arm-runner.env "$RENV"; w /etc/rlp/arm-api.env "$AENV"
for u in runner api; do
  f=/etc/systemd/system/rlp-$u.service.d/zz-arm.conf
  if sudo test -s /etc/rlp/arm-$u.env; then printf '[Service]\nEnvironmentFile=/etc/rlp/arm-%s.env\n' $u | sudo tee $f >/dev/null; else sudo rm -f $f; fi
done
# stale pool cgroups from a previous arm's runner pid
sudo find /sys/fs/cgroup/rlp.slice/vms -maxdepth 1 -name 'vm-pool-*' -exec rmdir {} + 2>/dev/null
sudo systemctl daemon-reload; sudo systemctl restart rlp-api; sleep 3; sudo systemctl restart rlp-runner
for i in $(seq 1 120); do curl -fsS -m 2 http://127.0.0.1:8088/health >/dev/null 2>&1 && break; sleep 1; done
# the runner reconciles the pool on startup: the count is briefly high (stale slots), drops, then refills.
# Require it high on two consecutive samples 10s apart so we do not start on the transient.
ok=0; for i in $(seq 1 180); do n=$(sudo ip netns list 2>/dev/null | wc -l)
  if [ "$n" -ge 1995 ]; then ok=$((ok+1)); [ $ok -ge 2 ] && break; else ok=0; fi; sleep 10; done
sleep 5
echo "== ARM $TAG  initdisk=$(renv rlp-runner RLP_INITDISK_MODE || echo copy) neigh=$(renv rlp-runner RLP_NEIGH_PERMANENT || echo 0) cgpool=$(renv rlp-runner RLP_CGROUP_POOL || echo 0) backlog=$(ss -ltn 'sport = :8088' | awk 'NR==2{print $2+$3}') pool=$(sudo ip netns list | wc -l) cgpool_ready=$(sudo ls /sys/fs/cgroup/rlp.slice/vms | grep -c '^vm-pool-')"
A=$(nstat -az TcpExtListenOverflows | tail -1 | awk '{print $2}')
bash $S/steps-run.sh $TAG $MODE $COUNT alpine:3.20 16 > $S/arm-$TAG.out 2>&1
B=$(nstat -az TcpExtListenOverflows | tail -1 | awk '{print $2}')
grep -E "^1 |^2 |^5 |^9b|^9c|^9e|^9f|TOTAL|POST -> client sees running|POST -> first exec" $S/arm-$TAG.out
echo "   listen_overflows=$((B-A))  $(grep -oE 'ok=[0-9]+ failed=[0-9]+|client_failed=[0-9]+' $S/arm-$TAG.out | tail -1)"
if [ "$MODE" = seq ]; then
  D=$(ls -dt /mnt/data/bench/steps-*-$TAG | head -1)
  python3 -c "
import re,sys
v=[int(m.group(1)) for m in (re.search(r'toolbox_wait_ms=(\d+)',l) for l in open(sys.argv[1])) if m]
s=sum(1 for x in v if x>100)
print(f'   toolbox_wait: n={len(v)} stalled(>100ms)={s} ({100*s/max(1,len(v)):.0f}%) max={max(v)} ms')" $D/runner.log
fi
