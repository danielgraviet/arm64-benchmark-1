#!/bin/bash
# A/B: cgroup2 favordynmods (cheap cgroup.procs migration) on the 1k alpine burst. Restores original options at exit.
S=/home/daytona/steps; ORIG=$(findmnt -no OPTIONS /sys/fs/cgroup | tr ',' '\n' | grep -E '^(nsdelegate|memory_recursiveprot|memory_localevents|memory_hugetlb_accounting|pids_localevents)$' | paste -sd,)
setfdm() { if [ $1 = on ]; then sudo mount -o remount,$ORIG,favordynmods /sys/fs/cgroup; else sudo mount -o remount,$ORIG /sys/fs/cgroup; fi; }
trap 'setfdm off; echo "restored: $(findmnt -no OPTIONS /sys/fs/cgroup)"' EXIT
for arm in off on on off; do
  setfdm $arm; echo "== favordynmods=$arm  mount: $(findmnt -no OPTIONS /sys/fs/cgroup)"
  sudo bpftrace $S/procs.bt $(pgrep -nx rlp-runner) > $S/procs-$arm.out 2>&1 & sleep 4
  bash $S/steps-run.sh burst-alpine-fdm-$arm burst 1000 alpine:3.20 16 > $S/fdm-$arm.out 2>&1
  sudo kill -INT $(pgrep -x bpftrace); sleep 3
  grep -E "POST -> client sees running|^5 |^9b|^9c|^9f|^2 " $S/fdm-$arm.out
  grep -A12 "@join_us" $S/procs-$arm.out | grep -E "\[|join"; grep "@join_sum_ms" $S/procs-$arm.out
done
