#!/bin/bash
# Build + publish the rlp-rs-0.4.1 daemon (e2d3e2759, Aug 17) for arm64 — the daemon every AMD bench cell runs.
set -u
B=$HOME/rlp-build; D=$B/d041; R=/mnt/data/rlp; L=$B/logs
sudo rm -rf $D && mkdir -p $D && tar xzf $B/d041.tgz -C $D
( cd $D/daemon && sudo bash ./build.sh ) > $L/d041-daemon.log 2>&1 || { echo "daemon build FAILED"; tail -6 $L/d041-daemon.log; exit 1; }
( cd $D/daemon && sudo bash ./build-git.sh ) > $L/d041-git.log 2>&1 || { echo "git tree build FAILED"; tail -6 $L/d041-git.log; exit 1; }
ls -la $D/daemon/dist/
GT=$(ls -d $D/daemon/dist/git-tree 2>/dev/null || ls -d $D/daemon/dist/*git* | head -1)
( cd $D && sudo RLP_DAEMON_ARCH=arm64 RLP_NFS_ROOT=$R RLP_GIT_TREE=$GT bash tools/daemon/convert-system-layer.sh $D/daemon/dist/rlp-daemon rlp-rs-0.4.1 ) > $L/d041-layer.log 2>&1 \
  || { echo "layer FAILED"; tail -8 $L/d041-layer.log; exit 1; }
tail -8 $L/d041-layer.log
echo "pointer: $(sudo cat $R/system/daemon-arm64.json 2>/dev/null || sudo cat $R/system/daemon.json)"
