#!/bin/bash
# Verify (a) nobody else is using the box and (b) the configuration is yesterday's final
# fixes-on state. Prints PASS/FAIL per check; exit 1 if any FAIL.
fail=0
chk() { printf '%-30s %-5s %s\n' "$1" "$2" "$3"; [ "$2" = FAIL ] && fail=1; return 0; }
want() { # name expected actual
  if [ "$2" = "$3" ]; then chk "$1" OK "$3"; else chk "$1" FAIL "got '$3' want '$2'"; fi; }
renv() { sudo bash -c "tr '\0' '\n' < /proc/\$(pgrep -nx $1)/environ" 2>/dev/null | grep -oP "^$2=\K.*"; }

echo "===== A. is anyone else using it"
chk logins_now $([ "$(who | wc -l)" -le 1 ] && echo OK || echo FAIL) "$(who | tr '\n' ';' | sed 's/;$//')"
chk tmux_sessions $([ -z "$(tmux ls 2>/dev/null)" ] && echo OK || echo FAIL) "$(tmux ls 2>&1 | head -2 | tr '\n' ' ')"
BP=$(pgrep -af 'main\.py --benchmark|mpfleet\.py|rlp_light_create_fleet|gapfill\.sh|ph-waves|ph-ladder|ph-fixed' | grep -v pgrep | wc -l)
chk bench_processes $([ "$BP" = 0 ] && echo OK || echo FAIL) "$BP running"
chk firecrackers $([ "$(pgrep -c firecracker)" = 0 ] && echo OK || echo FAIL) "$(pgrep -c firecracker)"
chk live_vm_rows SKIP "docker exec unusable while / is read-only"
chk recent_logins INFO "$(last -n 4 -w 2>/dev/null | head -4 | awk '{print $1"@"$3" "$4" "$5" "$6}' | tr '\n' ';')"
chk load INFO "$(cut -d' ' -f1-3 /proc/loadavg)"

echo "===== B. services and binaries (yesterday's fixes build)"
want services "active active active" "$(systemctl is-active rlp-api rlp-proxy rlp-runner | tr '\n' ' ' | sed 's/ $//')"
want runner_sha 365db3e34b3a "$(sha256sum /usr/local/bin/rlp-runner | cut -c1-12)"
want api_sha    eba93b695d5a "$(sha256sum /opt/rlp/rlp-api | cut -c1-12)"
want api_running_sha eba93b695d5a "$(sudo sha256sum /proc/$(pgrep -nx rlp-api)/exe 2>/dev/null | cut -c1-12)"
want fc_sha 2fd0171309af "$(sha256sum /usr/local/bin/firecracker | cut -c1-12)"

echo "===== C. the four create-path fixes, live"
want initdisk_mode nofsync "$(renv rlp-runner RLP_INITDISK_MODE)"
want cgroup_pool   2400    "$(renv rlp-runner RLP_CGROUP_POOL)"
want neigh_perm    1       "$(renv rlp-runner RLP_NEIGH_PERMANENT)"
want api_backlog   4096    "$(renv rlp-api RLP_API_LISTEN_BACKLOG)"
want listen_sendq  4096    "$(ss -ltn | awk '$4 ~ /:8088$/ {print $3; exit}')"
P=$(sudo ls /sys/fs/cgroup/rlp.slice/vms 2>/dev/null | grep -c '^vm-pool-')
chk cgroup_pool_dirs $([ "$P" -ge 2000 ] && echo OK || echo FAIL) "$P pre-created"
NS=$(sudo ip netns list | head -1 | awk '{print $1}')
chk neigh_in_netns "$(sudo ip netns exec $NS ip neigh show nud permanent 2>/dev/null | grep -q 10.255.0.2 && echo OK || echo FAIL)" "$(sudo ip netns exec $NS ip neigh show nud permanent 2>/dev/null | head -1)"

echo "===== D. earlier fixes and raised caps"
want fc_sock_wait  30000 "$(renv rlp-runner RLP_FC_SOCK_WAIT_MS)"
want balloon       0     "$(renv rlp-runner RLP_BALLOON)"
want vm_concurrency 512  "$(renv rlp-runner RLP_VM_CONCURRENCY)"
want max_live_vms  20000 "$(renv rlp-runner RLP_MAX_LIVE_VMS)"
want netns_pool    6200  "$(renv rlp-runner RLP_NETNS_POOL)"
want subnet        10.102.0.0/18 "$(renv rlp-runner RLP_SUBNET_CIDR)"
want queued_creates 40000 "$(renv rlp-api RLP_MAX_QUEUED_CREATES)"
want create_queue_secs 600 "$(renv rlp-api RLP_CREATE_MAX_QUEUE_SECS)"
chk sudo_storm_fix "$(grep -qa RLP_PRIV_EXEC_CONCURRENCY /usr/local/bin/rlp-runner && echo OK || echo FAIL)" "RLP_PRIV_EXEC_CONCURRENCY in binary; runner uid=$(sudo awk '/^Uid:/{print $2}' /proc/$(pgrep -nx rlp-runner)/status)"

echo "===== E. host posture"
N=$(sudo ip netns list | wc -l); chk netns_pool_warm $([ "$N" -ge 6100 ] && echo OK || echo FAIL) "$N"
want hugepages 0 "$(cat /proc/sys/vm/nr_hugepages)"
want numa_balancing 0 "$(cat /proc/sys/kernel/numa_balancing)"
want arp_gc3 65536 "$(sysctl -n net.ipv4.neigh.default.gc_thresh3)"
want slice_cpuset 0-383 "$(cat /sys/fs/cgroup/rlp.slice/cpuset.cpus.effective 2>/dev/null)"
want mnt_data "/dev/nvme0n1" "$(findmnt -no SOURCE /mnt/data)"
chk mnt_data_free INFO "$(df -h --output=avail /mnt/data | tail -1 | tr -d ' ')"
chk udev_shadow $([ -f /etc/udev/rules.d/70-iscsi-network-interface.rules ] && echo OK || echo FAIL) "iscsi rule shadowed"
chk template_cas INFO "$(sudo ls /mnt/data/rlp/templates 2>/dev/null | wc -l) template blobs"
chk disk_errors $([ "$(sudo dmesg -T 2>/dev/null | grep -ciE 'I/O error|medium error|nvme.*reset' )" = 0 ] && echo OK || echo FAIL) "$(sudo dmesg -T 2>/dev/null | grep -iE 'I/O error|medium error|nvme.*reset' | tail -2 | tr '\n' ';')"

echo "===== F. harness readiness for the agent ladder"
cd ~/arm64-benchmark-1 2>/dev/null || { chk harness FAIL "missing"; exit 1; }
chk harness_target "$(grep -q 'phoenix-e6' harness/regions.py && echo OK || echo FAIL)" "phoenix-e6 in regions.py"
chk main_py "$([ -f main.py ] && echo OK || echo FAIL)" "$(ls main.py 2>/dev/null)"
chk main_target_choices INFO "$(grep -n 'phoenix-e6' main.py | head -2 | tr '\n' ' ')"
chk agent_snapshot INFO "$(grep -rn 'vera-agent-benchmark' harness/benchmarks.py | head -1 | cut -c1-90)"
echo
[ $fail = 0 ] && echo "STATE VERIFY: PASS" || echo "STATE VERIFY: FAIL"
exit $fail
