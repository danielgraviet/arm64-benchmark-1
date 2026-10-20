#!/bin/bash
# Run ON the 9575F. Pushes the shared x86 cell artifacts + harness to the Phoenix E6 box.
set -eu
PH="ubuntu@<turin-host>"
K="-i /root/.ssh/ph_key -o StrictHostKeyChecking=accept-new"
say() { echo "[$(date -u +%T)] $*"; }
ssh $K $PH 'sudo mkdir -p /mnt/data/rlp && sudo chown -R ubuntu:ubuntu /mnt/data/rlp'
say "nfs00 (kernel, system, layers, manifests)"
tar c -C /mnt/nvme1/rlp/nfs00 kernel system layers manifests | ssh $K $PH 'tar x -C /mnt/data/rlp'
say "initdisk"
scp $K -q /var/lib/rlp/initdisk-rlp.ext4 $PH:/tmp/initdisk-rlp.ext4
say "harness (no data/, no daniel-focus-here/)"
tar c -C /home/ubuntu --exclude=arm64-benchmark-1/data --exclude=arm64-benchmark-1/daniel-focus-here --exclude=.venv --exclude=.git arm64-benchmark-1 | ssh $K $PH 'tar x -C /home/ubuntu'
say "sdk"
tar c -C /home/ubuntu --exclude=.git --exclude=node_modules rlp | ssh $K $PH 'tar x -C /home/ubuntu'
say "done"
ssh $K $PH 'du -sh /mnt/data/rlp/* ~/arm64-benchmark-1 ~/rlp; ls /mnt/data/rlp/kernel'
