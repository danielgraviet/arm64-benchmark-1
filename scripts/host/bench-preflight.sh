#!/bin/bash
# bench-preflight.sh — record + gate the host state before ANY benchmark run.
# Every confounder found in the Vera/EPYC investigation is either asserted (FAIL) or recorded (INFO).
# Usage: sudo scripts/host/bench-preflight.sh <outdir>   exit 1 if a FAIL check trips.
# See docs/benchmark-methodology.md for why each gate exists.
OUT=${1:-/tmp/preflight-$(date -u +%Y%m%d_%H%M%S)}; mkdir -p "$OUT"; F=$OUT/preflight.txt
fail=0
chk() { # chk NAME OK|FAIL|INFO VALUE
  printf '%-28s %-5s %s\n' "$1" "$2" "$3" | tee -a $F; [ "$2" = FAIL ] && fail=1; }
PG() { # bridge-network container (default socket) OR host-network container on :5439
  docker exec -i rlp-postgres psql -U rlp -d rlplatform -tAc "$1" 2>/dev/null \
    || docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1" 2>/dev/null; }
: > $F
# --- hard gates: each of these distorted a published result ---
n=$(pgrep -fc 'rlp-cpu-weight-floor' || true); chk floor_script $([ "$n" = 0 ] && echo OK || echo FAIL) "procs=$n (doubled 9575F startup)"
top=$(top -b -n 2 -d 3 -w 200 | awk '/^top -/{n++} n==2 && $1~/^[0-9]+$/ && $9+0>20 && $12!~/^(top|sshd|bash|tmux|kworker|rcu_|ksoftirq|migration)/{print $12"="$9"%"}' | head -5 | tr '\n' ' ')
pool=$(ip netns list 2>/dev/null | wc -l); want=$(tr '\0' '\n' </proc/$(pgrep -nx rlp-runner)/environ 2>/dev/null | grep -oP '^RLP_NETNS_POOL=\K.*')
chk netns_pool_warm $([ "$pool" -ge $(( ${want:-0} * 95 / 100 )) ] && echo OK || echo FAIL) "$pool/${want:-?} (a filling pool burns CPU during the run)"
chk background_cpu $([ -z "$top" ] && echo OK || echo FAIL) "${top:-none >20%}"
fc=$(pgrep -c firecracker || true); live=$(PG "select count(*) from vms where status not in ('deleted','failed','lost')")
chk clean_fleet $([ "$fc" = 0 ] && [ "${live:-0}" = 0 ] && echo OK || echo FAIL) "firecracker=$fc live_rows=${live:-?}"
hp=$(cat /proc/sys/vm/nr_hugepages); chk hugepages_reserved $([ "$hp" = 0 ] && echo OK || echo FAIL) "nr_hugepages=$hp (E2B reserves 1.44 TB at boot)"
ma=$(awk '/MemAvailable/{printf "%d",$2/1048576}' /proc/meminfo); chk mem_available $([ "$ma" -gt 500 ] && echo OK || echo FAIL) "${ma} GiB"
ro=$(PG "select count(*) from runners where status='online'"); chk runner_online $([ "${ro:-0}" -ge 1 ] && echo OK || echo FAIL) "online=$ro"
gc=$(sysctl -n net.ipv4.neigh.default.gc_thresh3); chk arp_gc_thresh3 $([ "$gc" -ge 65536 ] && echo OK || echo FAIL) "$gc (1024 caps density ~1k)"
bal=$(tr '\0' '\n' </proc/$(pgrep -nx rlp-runner)/environ 2>/dev/null | grep -oP '^RLP_BALLOON=\K.*'); chk balloon_off $([ "${bal:-0}" = 0 ] && echo OK || echo FAIL) "RLP_BALLOON=${bal:-unset} (corrupts guests on 64 KiB hosts)"
nf=$(ulimit -Hn); chk client_nofile_hard $([ "$nf" -ge 1048576 ] && echo OK || echo FAIL) "$nf"
# --- recorded conditions (must be reported with results) ---
chk cpu INFO "$(lscpu | awk -F: '/Model name/{gsub(/^ +/,"",$2);print $2; exit}') sockets=$(lscpu | awk -F: '/Socket/{gsub(/ /,"",$2);print $2}') online=$(cat /sys/devices/system/cpu/online)"
chk kernel INFO "$(uname -r) page=$(getconf PAGESIZE)"
chk cmdline INFO "$(cat /proc/cmdline)"
chk numa_balancing INFO "$(cat /proc/sys/kernel/numa_balancing)"
chk governor_idle INFO "governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null) idle=$(cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null) max_khz=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null)"
chk power_cap INFO "$(cat /sys/class/hwmon/*/power1_cap 2>/dev/null | awk '{printf "%dW ",$1/1e6}')"
chk kvm INFO "halt_poll_ns=$(cat /sys/module/kvm/parameters/halt_poll_ns 2>/dev/null) mode=$(grep -oE 'kvm-arm.mode=[a-z]+' /proc/cmdline)"
for b in rlp-runner rlp-proxy firecracker; do chk bin_$b INFO "sha=$(sha256sum /usr/local/bin/$b | cut -c1-12)"; done
chk bin_rlp-api INFO "sha=$(sha256sum $(readlink -f /proc/$(pgrep -nx rlp-api)/exe) 2>/dev/null | cut -c1-12) path=$(readlink -f /proc/$(pgrep -nx rlp-api)/exe)"
chk build INFO "$(cat /etc/rlp/BUILD 2>/dev/null)"
chk slice_cpus INFO "rlp.slice=$(cat /sys/fs/cgroup/rlp.slice/cpuset.cpus.effective 2>/dev/null) runner=$(awk '/Cpus_allowed_list/{print $2}' /proc/$(pgrep -nx rlp-runner)/status 2>/dev/null) api=$(awk '/Cpus_allowed_list/{print $2}' /proc/$(pgrep -nx rlp-api)/status 2>/dev/null)"
chk runner_env INFO "$(tr '\0' '\n' </proc/$(pgrep -nx rlp-runner)/environ 2>/dev/null | grep -E '^RLP_(VM_CONCURRENCY|NETNS_POOL|MAX_LIVE_VMS|SNAPSHOTS|TEMPLATE_BUILD_AFTER|QUIET_PROGRESS|RESERVE_PCT|FC_SOCK_WAIT_MS|INITDISK_MODE|CGROUP_POOL|NEIGH_PERMANENT)=' | tr '\n' ' ')"
# Create-path fixes (daytona/rlp#3260 #3261 #3265 #3269): patched builds only. ON/OFF changes 1k-burst startup ~30-45%,
# so every result must say which. Read from the live processes, not the env files.
_re() { tr '\0' '\n' </proc/$(pgrep -nx $1)/environ 2>/dev/null | grep -oP "^$2=\K.*"; }
_fx="initdisk=$(_re rlp-runner RLP_INITDISK_MODE) cgroup_pool=$(_re rlp-runner RLP_CGROUP_POOL) neigh=$(_re rlp-runner RLP_NEIGH_PERMANENT) backlog=$(ss -ltn 'sport = :8088' 2>/dev/null | awk 'NR==2{print $2+$3}')"
case "$_fx" in *initdisk=nofsync*cgroup_pool=[1-9]*neigh=1*backlog=4096*) _st=ON ;; *initdisk=\ cgroup_pool=\ neigh=\ *) _st=OFF ;; *) _st=PARTIAL ;; esac
chk create_path_fixes INFO "$_st ($_fx)"
chk api_env INFO "$(tr '\0' '\n' </proc/$(pgrep -nx rlp-api)/environ 2>/dev/null | grep -E '^RLP_(EVENT_AUDIT|MIN_CPU|MIN_MEM_MIB|MIN_SCRATCH_MIB|BURST_MAX_CPU|BURST_MAX_MEM_MIB|API_LISTEN_BACKLOG)=' | tr '\n' ' ')"
chk disk INFO "$(df -h --output=source,size,avail /mnt/data | tail -1)"
echo "PREFLIGHT $([ $fail = 0 ] && echo PASS || echo FAIL) -> $F" | tee -a $F
exit $fail
