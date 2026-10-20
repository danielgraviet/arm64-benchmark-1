#!/bin/bash
# cgroup mkdir throughput under rlp.slice with the same controllers as rlp.slice/vms (host idle, 0 sandboxes).
P=/sys/fs/cgroup/rlp.slice/cgbench
echo "vms subtree_control: $(cat /sys/fs/cgroup/rlp.slice/vms/cgroup.subtree_control) | rlp.slice: $(cat /sys/fs/cgroup/rlp.slice/cgroup.subtree_control) | nr_cpus=$(nproc)"
sudo mkdir -p $P; echo "$(cat /sys/fs/cgroup/rlp.slice/vms/cgroup.subtree_control | sed 's/\([a-z]*\)/+\1/g')" | sudo tee $P/cgroup.subtree_control >/dev/null
echo "cgbench subtree_control: $(cat $P/cgroup.subtree_control)"
run() { # $1 label $2 parallelism
  local t0=$(date +%s.%N)
  seq 1000 | sudo xargs -P $2 -I{} mkdir $P/c{}
  local t1=$(date +%s.%N)
  seq 1000 | sudo xargs -P $2 -I{} rmdir $P/c{}
  local t2=$(date +%s.%N)
  echo "$1: 1000 mkdir in $(echo "$t1-$t0" | bc) s, 1000 rmdir in $(echo "$t2-$t1" | bc) s"
}
run "serial      " 1; run "parallel-256" 256; run "serial again" 1
# the same with only cpu enabled (what the runner actually uses: cpu.weight)
echo "-cpuset -memory -io -pids" | tr ' ' '\n' | while read c; do echo "$c" | sudo tee $P/cgroup.subtree_control >/dev/null 2>&1; done
echo "cgbench subtree_control now: $(cat $P/cgroup.subtree_control)"
run "cpu-only serial" 1; run "cpu-only parallel-256" 256
sudo rmdir $P
