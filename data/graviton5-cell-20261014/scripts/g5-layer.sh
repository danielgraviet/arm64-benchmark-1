#!/bin/bash
# Publish guest kernel + the rlp-rs-0.4.1 daemon layer (e2d3e2759, 4 KiB EROFS) to the artifact root — as on HQ Vera.
set -euo pipefail
B=$HOME/rlp-build; D=$B/d041; R=/mnt/data/rlp; O=$B/out
sudo mkdir -p $R/{kernel,system,layers/sha256,manifests,templates,scratch,pg,nats} /var/lib/rlp
sudo cp $O/kernel/Image-6.12.34-rlp1-arm64 $R/kernel/
ls -la $D/daemon/dist/
GT=$(ls -d $D/daemon/dist/git-tree 2>/dev/null || ls -d $D/daemon/dist/*git* | head -1)
( cd $D && sudo RLP_DAEMON_ARCH=arm64 RLP_NFS_ROOT=$R RLP_GIT_TREE=$GT bash tools/daemon/convert-system-layer.sh $D/daemon/dist/rlp-daemon rlp-rs-0.4.1 ) > $B/logs/d041-layer.log 2>&1 \
  || { echo "layer FAILED"; tail -8 $B/logs/d041-layer.log; exit 1; }
tail -4 $B/logs/d041-layer.log
echo "daemon size: $(stat -c %s $D/daemon/dist/rlp-daemon) (HQ Vera arm64: 3741568)"
echo "pointer: $(sudo cat $R/system/daemon-arm64.json 2>/dev/null || sudo cat $R/system/daemon.json)"
