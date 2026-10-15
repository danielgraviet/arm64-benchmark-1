#!/bin/bash
# Build the x86_64 rlp binaries for the Phoenix E6 bench cell, from the same source
# tree as the HQ Vera cell: f0611fa13 + 6883d3366 (erofs -b 4096) + RLP_FC_SOCK_WAIT_MS
# + 8d2b090ff RLP_FC_SMT (inactive). Containerized; nothing installed on the host.
set -u
B=$HOME/rlp-build; S=$B/src; O=$B/out; L=$B/logs; mkdir -p $O $L
D="sudo docker"
log() { echo "$(date -u +%T) $*" | tee -a $L/status; }

log "=== build start (nproc=$(nproc))"

# 1) Go binaries: runner, fcns, egressd, proxy
log "START go"
$D run --rm -v $S:/src -v $B/gocache:/root/.cache/go-build -v $B/gomod:/go/pkg/mod -w /src golang:1.25-bookworm bash -c '
  set -e
  cd /src/runner && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o /src/.out-rlp-runner  ./cmd/runner
  cd /src/runner && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o /src/.out-rlp-fcns    ./cmd/rlp-fcns
  cd /src/runner && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o /src/.out-rlp-egressd ./cmd/egressd
  cd /src/proxy  && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o /src/.out-rlp-proxy   ./cmd/proxy
' > $L/go.log 2>&1; rc=$?
for n in rlp-runner rlp-fcns rlp-egressd rlp-proxy; do [ -f $S/.out-$n ] && mv $S/.out-$n $O/$n; done
log "go rc=$rc -> $(ls $O | tr '\n' ' ')"
[ $rc -eq 0 ] || { tail -20 $L/go.log; exit 1; }

# 2) API (Rust, rustls; aws-lc needs cmake/clang)
log "START api"
$D run --rm -v $S:/src -v $B/cargo:/usr/local/cargo/registry -w /src/api rust:1-bookworm bash -c \
  'apt-get update -qq && apt-get install -y -qq cmake clang >/dev/null && cargo build --release && cp target/release/rlp-api /src/.out-rlp-api' \
  > $L/api.log 2>&1; rc=$?
[ -f $S/.out-rlp-api ] && sudo mv $S/.out-rlp-api $O/rlp-api && sudo chown $USER $O/rlp-api
log "api rc=$rc"
[ $rc -eq 0 ] || { tail -20 $L/api.log; exit 1; }

# 3) Firecracker v1.16.1 x86_64, sha pinned in deploy/bin/SHA256SUMS
log "START firecracker"
cd $B && rm -rf release-v1.16.1-x86_64
curl -fsSL https://github.com/firecracker-microvm/firecracker/releases/download/v1.16.1/firecracker-v1.16.1-x86_64.tgz | tar xz
sha=$(sha256sum release-v1.16.1-x86_64/firecracker-v1.16.1-x86_64 | cut -d' ' -f1)
want=$(awk '/firecracker$/{print $1}' $S/deploy/bin/SHA256SUMS)
[ "$sha" = "$want" ] || { log "FIRECRACKER SHA MISMATCH got=$sha want=$want"; exit 1; }
cp release-v1.16.1-x86_64/firecracker-v1.16.1-x86_64 $O/firecracker
cp release-v1.16.1-x86_64/snapshot-editor-v1.16.1-x86_64 $O/snapshot-editor 2>/dev/null || true
log "firecracker sha OK ($sha)"

log "=== ALL BUILDS DONE"
ls -l $O
( cd $O && sha256sum * )
