#!/bin/bash
# Build Firecracker v1.16.1 + NVIDIA's CURRENT aarch64 SMT series as 1.16.1-rlpsmt2.
# The original rlpsmt1 commits (0083bd93c bffe37814 87720db90 c8f1c512e) were force-pushed away from
# NathanChenNVIDIA/firecracker; that branch is now aarch64-smt-support-aug with a different implementation
# (FDT cpu-map only; no per-vCPU MPIDR_EL1 write). Patches here = that branch's f85c6355 1f44f37d 6fb966c8
# bf4c1089 cherry-picked onto v1.16.1, cosmetic conflicts (CHANGELOG, tests) resolved.
set -euo pipefail
W=${1:-/mnt/data/fc-smt2-build}; PATCHES=${2:-$HOME/rlp-build/smt2-patches}
VER=1.16.1-rlpsmt2; TARGET=aarch64-unknown-linux-musl
[ "$(uname -m)" = aarch64 ] || { echo "aarch64 only"; exit 1; }
mkdir -p $W && cd $W
[ -d firecracker/.git ] || git clone -q https://github.com/firecracker-microvm/firecracker.git
cd firecracker
git fetch -q origin --tags
git am --abort 2>/dev/null || true
git checkout -q --detach v1.16.1
git branch -qD v1.16.1-rlp-smt2 2>/dev/null || true
git checkout -q -b v1.16.1-rlp-smt2
git -c user.name=bench -c user.email=bench@local am -q $PATCHES/*.patch
sed -i "0,/^version = \"1.16.1\"/s//version = \"$VER\"/" src/firecracker/Cargo.toml
grep -q "^version = \"$VER\"" src/firecracker/Cargo.toml
tools/devtool -y build --release
OUT=build/cargo_target/$TARGET/release
"$OUT/firecracker" --version | head -1
file "$OUT/firecracker" | grep -q "statically linked"
"$OUT/firecracker" --version | head -1 | grep -q "$VER"
sha256sum "$OUT/firecracker"
echo "BUILT $W/firecracker/$OUT/firecracker"
