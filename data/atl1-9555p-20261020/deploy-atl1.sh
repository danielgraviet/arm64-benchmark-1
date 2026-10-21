#!/bin/bash
# atl1node853 (EPYC 9555P): deploy the bench build used for the 2026-10-14/15 baselines (byte-identical to the
# EPYC 9575F's binaries, harness, SDK and Python), align the cell config with the baseline cells, fixes ON.
# Everything replaced is backed up to /etc/rlp/backup-sep15-<stamp>/ (+ a pg_dump).
set -u
B=/etc/rlp/backup-sep15-$(date -u +%Y%m%d_%H%M%S); H=/etc/rlp/HOSTCHANGES; touch $H
log() { echo "$(date -u +%T) $*"; echo "$(date -u +%FT%TZ) $*" >> $H; }
[ -z "$(who)" ] || { echo "ABORT: someone is logged in: $(who)"; exit 1; }
mkdir -p $B /mnt/data/backup
cp -a /usr/local/bin/rlp-runner /usr/local/bin/rlp-api /usr/local/bin/rlp-fcns /usr/local/bin/rlp-proxy /etc/rlp/*.env /etc/systemd/system/rlp-runner.service $B/
docker exec rlp-postgres pg_dump -U rlp -Fc rlplatform > /mnt/data/backup/rlplatform-$(date -u +%Y%m%d_%H%M%S).dump && log "backup: binaries/env/unit -> $B, pg_dump -> /mnt/data/backup/"
systemctl stop rlp-proxy rlp-runner rlp-api
n=$(pgrep -c firecracker); pkill -9 -x firecracker; sleep 2; rm -rf /run/fc/* 2>/dev/null
m=$(docker exec rlp-postgres psql -U rlp -d rlplatform -tAc "update vms set status='deleted' where status not in ('deleted','failed','lost') returning id" | grep -c .)
log "cleaned Sep 15 leftovers: killed $n idle firecrackers, marked $m stale vms rows deleted"
tar xzf /tmp/bundle.tgz -C /
cp /tmp/regions.py /home/ubuntu/arm64-benchmark-1/harness/regions.py
log "installed bench build from the EPYC 9575F: runner $(sha256sum /usr/local/bin/rlp-runner|cut -c1-12) api $(sha256sum /usr/local/bin/rlp-api|cut -c1-12) fcns $(sha256sum /usr/local/bin/rlp-fcns|cut -c1-12) proxy $(sha256sum /usr/local/bin/rlp-proxy|cut -c1-12); harness+SDK+python at the same /home/ubuntu paths; harness regions.py += atl1 target (same handling as epyc9575)"
# --- cell config aligned with the baseline cells (HQ Vera / 9575F) ---
setkv() { f=$1; k=$2; v=$3; if grep -q "^$k=" $f; then sed -i "s|^$k=.*|$k=$v|" $f; else echo "$k=$v" >> $f; fi; }
setkv /etc/rlp/runner.env RLP_SNAPSHOTS 1
setkv /etc/rlp/runner.env RLP_VM_CONCURRENCY 512
setkv /etc/rlp/runner.env RLP_NETNS_POOL 2100
setkv /etc/rlp/runner.env RLP_CGROUP_ROOT /sys/fs/cgroup/rlp.slice/vms
setkv /etc/rlp/api.env RLP_BURST_MAX_CPU 1
setkv /etc/rlp/api.env RLP_BURST_MAX_MEM_MIB 4096
setkv /etc/rlp/api.env RLP_MIN_SCRATCH_MIB 16
log "config aligned with baseline cells: runner RLP_SNAPSHOTS=1 (was unset -> snapshot clones were OFF, every create cold-booted), VM_CONCURRENCY 128->512, NETNS_POOL 1100->2100, CGROUP_ROOT rlp.slice/vms; api BURST_MAX_CPU=1 (was unset = 16), BURST_MAX_MEM_MIB 512->4096, MIN_SCRATCH_MIB 1024->16"
mkdir -p /etc/systemd/system/rlp-runner.service.d /etc/systemd/system/rlp-api.service.d
printf '[Service]\n# delegated cgroup subtree, as on the baseline cells\nSlice=rlp.slice\nExecStartPre=+/usr/local/bin/rlp-cgroup-setup\n' > /etc/systemd/system/rlp-runner.service.d/10-slice.conf
echo "RLP_FC_SOCK_WAIT_MS=30000" > /etc/rlp/bench-common-runner.env
printf '[Service]\n# as on HQ Vera / 9575F (daytona/rlp#3212)\nEnvironmentFile=/etc/rlp/bench-common-runner.env\n' > /etc/systemd/system/rlp-runner.service.d/15-bench-common.conf
printf 'RLP_INITDISK_MODE=nofsync\nRLP_CGROUP_POOL=1400\nRLP_NEIGH_PERMANENT=1\n' > /etc/rlp/create-path-fixes-runner.env
printf 'RLP_API_LISTEN_BACKLOG=4096\n' > /etc/rlp/create-path-fixes-api.env
for u in runner api; do printf '[Service]\n# daytona/rlp#3260 #3261 #3265 #3269 -- create-path fixes ON\nEnvironmentFile=/etc/rlp/create-path-fixes-%s.env\n' $u > /etc/systemd/system/rlp-$u.service.d/20-create-path-fixes.conf; done
log "drop-ins: 10-slice.conf (Slice=rlp.slice + rlp-cgroup-setup), 15-bench-common.conf (RLP_FC_SOCK_WAIT_MS=30000), 20-create-path-fixes.conf (fixes ON, same values as the baselines)"
systemctl restart rlp-subnet-route; log "rlp-subnet-route restarted (priority-95 rule for 10.140.0.0/20 had disappeared): $(ip rule | grep -c '^95:') rule(s)"
install -m 755 /home/ubuntu/arm64-benchmark-1/scripts/host/bench-preflight.sh /usr/local/bin/bench-preflight
K=$(cat /etc/rlp/bench-api-key)
printf 'RLP_API_URL=http://127.0.0.1:8088\nRLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox\nRLP_API_KEY=%s\n' "$K" > /home/ubuntu/arm64-benchmark-1/.env; chmod 600 /home/ubuntu/arm64-benchmark-1/.env
systemctl daemon-reload
systemctl start rlp-api
for i in $(seq 1 180); do curl -fsS -m 2 http://127.0.0.1:8088/health >/dev/null 2>&1 && break; sleep 1; done
echo "api health $(curl -s -m 3 -o /dev/null -w %{http_code} http://127.0.0.1:8088/health); migrations now $(docker exec rlp-postgres psql -U rlp -d rlplatform -tAc 'select max(version)||'"' '"'||count(*) from _sqlx_migrations')"
journalctl -u rlp-api --since -4min --no-pager -o cat | grep -iE "migrat|error|backlog" | tail -4 | cut -c1-200
systemctl start rlp-runner rlp-proxy
ok=0; for i in $(seq 1 120); do n=$(ip netns list | wc -l); if [ $n -ge 1995 ]; then ok=$((ok+1)); [ $ok -ge 2 ] && break; else ok=0; fi; sleep 10; done
echo "runner=$(systemctl is-active rlp-runner) proxy=$(systemctl is-active rlp-proxy) netns=$(ip netns list | wc -l) slice=$(cat /sys/fs/cgroup/rlp.slice/cpuset.cpus.effective 2>/dev/null) runner_cg=$(cat /proc/$(pgrep -nx rlp-runner)/cgroup) cgpool=$(ls /sys/fs/cgroup/rlp.slice/vms 2>/dev/null | grep -c '^vm-pool-') backlog=$(ss -ltn 'sport = :8088' | awk 'NR==2{print $2+$3}')"
bench-preflight /tmp/pf-deploy 2>/dev/null | grep -E "FAIL|create_path_fixes|runner_env|PREFLIGHT"
log "deploy done"
