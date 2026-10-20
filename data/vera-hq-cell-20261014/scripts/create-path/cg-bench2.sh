#!/bin/bash
# cgroup mkdir/rmdir cost per controller set, 1000 cgroups, parallel 256 and serial. Throwaway parent under rlp.slice.
P=/sys/fs/cgroup/rlp.slice/cgbench2
echo "rlp.slice subtree: $(cat /sys/fs/cgroup/rlp.slice/cgroup.subtree_control) | vms subtree: $(cat /sys/fs/cgroup/rlp.slice/vms/cgroup.subtree_control) | nproc=$(nproc)"
run() { local t0=$(date +%s.%N); seq 1000 | sudo xargs -P $2 -I{} mkdir $P/c{}; local t1=$(date +%s.%N)
  seq 1000 | sudo xargs -P $2 -I{} rmdir $P/c{}; local t2=$(date +%s.%N)
  printf "  %-24s P=%-3s mkdir 1000: %.2f s   rmdir 1000: %.2f s\n" "$1" $2 $(echo "$t1-$t0" | bc) $(echo "$t2-$t1" | bc); }
for set in "cpu memory pids" "cpu memory" "cpu" "cpuset cpu memory pids"; do
  sudo mkdir -p $P; for c in $set; do echo "+$c" | sudo tee $P/cgroup.subtree_control >/dev/null; done
  for p in 256 1; do run "[$set]" $p; done
  sudo rmdir $P
done
