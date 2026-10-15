#!/bin/bash
# A/B: runner scratch dir (per-clone 16 MiB init-disk copy + fsync, templates) on root NVMe ext4 vs tmpfs.
S=/home/daytona/steps; T=/mnt/rlp-scratch-tmpfs
renv() { sudo cat /proc/$(pgrep -nx rlp-runner)/environ | tr '\0' '\n' | grep -oP "^$1=\K.*"; }
restart_wait() { sudo systemctl daemon-reload; sudo systemctl restart rlp-runner; sleep 5
  for i in $(seq 1 120); do n=$(sudo ip netns list | wc -l); [ $n -ge 1995 ] && break; sleep 5; done; echo "  pool=$(sudo ip netns list | wc -l) scratch=$(renv RLP_LOCAL_SCRATCH)"; sleep 10; }
revert() { sudo rm -f /etc/systemd/system/rlp-runner.service.d/zz-scratch.conf /etc/rlp/arm-scratch.env; restart_wait; }
trap 'echo "== revert"; revert; echo "  tmpfs left mounted at $T (unmount after verifying)"' EXIT
sudo mkdir -p $T; if mountpoint -q $T; then sudo mount -o remount,size=1200G $T; else sudo mount -t tmpfs -o size=1200G,mode=0755 tmpfs $T; fi; echo "  tmpfs: $(df -h $T | tail -1)"
echo "RLP_LOCAL_SCRATCH=$T" | sudo tee /etc/rlp/arm-scratch.env >/dev/null
printf '[Service]\nEnvironmentFile=/etc/rlp/arm-scratch.env\n' | sudo tee /etc/systemd/system/rlp-runner.service.d/zz-scratch.conf >/dev/null
echo "== TMPFS arm"; restart_wait
[ "$(renv RLP_LOCAL_SCRATCH)" = "$T" ] || { echo "FATAL: scratch env not applied"; exit 1; }
( cd $S && ~/arm64-benchmark-1/.venv/bin/python stepclient.py --mode seq --count 8 --image alpine:3.20 --out /tmp/tmpfs-warm.jsonl ) ; tail -1 /tmp/tmpfs-warm.jsonl
for r in 1 2; do bash $S/steps-run.sh burst-alpine-tmpfsB-$r burst 1000 alpine:3.20 16 > $S/tmpfsB-$r.out 2>&1
  echo "  tmpfs rep$r:"; grep -E "POST -> client sees running|^5 |^9b|^9c|^9f" $S/tmpfsB-$r.out; done
trap - EXIT; echo "== DISK arm (reverted)"; revert
for r in 1; do bash $S/steps-run.sh burst-alpine-diskB-$r burst 1000 alpine:3.20 16 > $S/diskB-$r.out 2>&1
  echo "  disk rep$r:"; grep -E "POST -> client sees running|^5 |^9b|^9c|^9f" $S/diskB-$r.out; done
echo "== done; tmpfs still mounted at $T"
