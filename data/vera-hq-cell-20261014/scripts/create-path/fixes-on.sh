#!/bin/bash
# Persistently enable the four create-path fixes on HQ Vera via a named drop-in (survives restarts/reboots).
# Remove: rm /etc/systemd/system/rlp-{runner,api}.service.d/20-create-path-fixes.conf && daemon-reload && restart.
set -u
sudo tee /etc/rlp/create-path-fixes-runner.env >/dev/null <<'E'
# Create-path fixes (patched runner 0fd55bab4ad6). See CREATE-PATH-STEPS.md / BASELINE-VERA-FIXES-20261014.md.
RLP_INITDISK_MODE=nofsync
RLP_CGROUP_POOL=1400
RLP_NEIGH_PERMANENT=1
E
sudo tee /etc/rlp/create-path-fixes-api.env >/dev/null <<'E'
# Create-path fix (patched api 1648ab971fe5): explicit accept backlog instead of mio's 128 (daytona/rlp#3269).
RLP_API_LISTEN_BACKLOG=4096
E
for u in runner api; do
  printf '[Service]\n# daytona/rlp#3260 #3261 #3265 #3269 -- patched build, measured 2026-10-14\nEnvironmentFile=/etc/rlp/create-path-fixes-%s.env\n' $u \
    | sudo tee /etc/systemd/system/rlp-$u.service.d/20-create-path-fixes.conf >/dev/null
done
sudo rm -f /etc/systemd/system/rlp-runner.service.d/zz-arm.conf /etc/systemd/system/rlp-api.service.d/zz-arm.conf /etc/rlp/arm-runner.env /etc/rlp/arm-api.env
sudo find /sys/fs/cgroup/rlp.slice/vms -maxdepth 1 -name 'vm-pool-*' -exec rmdir {} + 2>/dev/null
sudo systemctl daemon-reload; sudo systemctl restart rlp-api; sleep 3; sudo systemctl restart rlp-runner
for i in $(seq 1 120); do curl -fsS -m 2 http://127.0.0.1:8088/health >/dev/null 2>&1 && break; sleep 1; done
ok=0; for i in $(seq 1 180); do n=$(sudo ip netns list 2>/dev/null | wc -l); if [ "$n" -ge 1995 ]; then ok=$((ok+1)); [ $ok -ge 2 ] && break; else ok=0; fi; sleep 10; done
renv() { sudo cat /proc/$(pgrep -nx $1)/environ | tr '\0' '\n' | grep -E "$2"; }
echo "runner env: $(renv rlp-runner '^RLP_(INITDISK_MODE|CGROUP_POOL|NEIGH_PERMANENT|FC_SOCK_WAIT_MS)=' | tr '\n' ' ')"
echo "api env:    $(renv rlp-api '^RLP_API_LISTEN_BACKLOG=' | tr '\n' ' ')"
echo "live: backlog=$(ss -ltn 'sport = :8088' | awk 'NR==2{print $2+$3}') cgroup_pool_ready=$(sudo ls /sys/fs/cgroup/rlp.slice/vms | grep -c '^vm-pool-') netns=$(sudo ip netns list | wc -l)"
echo "neigh sample: $(for ns in $(sudo ip netns list | awk '{print $1}' | shuf -n 10); do sudo ip netns exec $ns ip neigh show 10.255.0.2 dev rlptap0; done | grep -c PERMANENT)/10 PERMANENT"
echo "$(date -u +%FT%TZ) CREATE-PATH FIXES ON persistently: drop-ins 20-create-path-fixes.conf -> /etc/rlp/create-path-fixes-{runner,api}.env (RLP_INITDISK_MODE=nofsync RLP_CGROUP_POOL=1400 RLP_NEIGH_PERMANENT=1; RLP_API_LISTEN_BACKLOG=4096). Benchmarks on this cell are now 'fixes on'." | sudo tee -a /etc/rlp/HOSTCHANGES >/dev/null
