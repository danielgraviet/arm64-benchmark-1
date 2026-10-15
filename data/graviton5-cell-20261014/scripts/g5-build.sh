#!/bin/bash
# Containerized builds on the Graviton5 host; same sources/recipes as the HQ Vera cell. Output: ~/rlp-build/out
set -u
B=$HOME/rlp-build; S=$B/src; O=$B/out; L=$B/logs; D=$B/d041
mkdir -p $O/kernel $L
log() { echo "$(date -u +%T) $*" >> $L/status; }
sudo rm -rf $S $D && mkdir -p $S $D && tar xzf $B/vera-src2.tgz -C $S && tar xzf $B/d041.tgz -C $D
log "=== BUILD start (src=vera-src2 f0611fa13+erofs4k, daemon=d041 e2d3e2759)"
( log "START kernel+initdisk"; sudo docker run --rm -v $S:/src -v $B/ksrc:/ksrc -v $O/kernel:/okernel -w /src ubuntu:24.04 bash -c \
   'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential bc bison flex libssl-dev libelf-dev dwarves cpio xz-utils curl ca-certificates kmod busybox-static e2fsprogs >/dev/null && \
    RLP_ARCH=arm64 RLP_SRC_DIR=/ksrc RLP_JOBS=160 RLP_NFS_KERNEL=/okernel bash guest/kernel/build-kernel.sh --config config-6.12.34-rlp1-arm64 --label rlp1-arm64 --install && \
    bash guest/scripts/build-initdisk.sh /okernel/initdisk-rlp.ext4 guest/init' > $L/kernel.log 2>&1; log "kernel+initdisk rc=$?" ) &
( log "START daemon"; cd $D/daemon && sudo bash ./build.sh > $L/d041-daemon.log 2>&1; rc=$?; log "daemon rc=$rc"
  sudo bash ./build-git.sh > $L/d041-git.log 2>&1; log "daemon git-tree rc=$?" ) &
( log "START api"; sudo docker run --rm -e CARGO_BUILD_JOBS=128 -v $S:/src -v $B/cargo:/usr/local/cargo/registry -w /src/api rust:1-bookworm bash -c \
   'apt-get update -qq && apt-get install -y -qq cmake clang >/dev/null && cargo build --release && cp target/release/rlp-api /src/rlp-api.out' > $L/api.log 2>&1; rc=$?
  sudo mv $S/rlp-api.out $O/rlp-api 2>/dev/null; log "api rc=$rc" ) &
wait
log "=== ALL BUILDS FINISHED"
