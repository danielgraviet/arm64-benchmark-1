#!/bin/bash
# Rebuild rlp-runner + rlp-api from the fixes tree (#3260/#3261/#3265 from the Vera bench
# build + #3269 implemented here). Keeps the current binaries as .bak-prefixes.
set -u
B=$HOME/rlp-build; S=$B/src-fixes; O=$B/out-fixes; L=$B/logs; mkdir -p $O $L
log() { echo "$(date -u +%T) $*"; }
log "building runner"
sudo docker run --rm -v $S:/src -v $B/gocache:/root/.cache/go-build -v $B/gomod:/go/pkg/mod -w /src golang:1.25-bookworm bash -c '
  set -e; cd /src/runner && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o /src/.out-rlp-runner ./cmd/runner' > $L/go-fixes.log 2>&1
rc=$?; [ -f $S/.out-rlp-runner ] && mv $S/.out-rlp-runner $O/rlp-runner; log "runner rc=$rc"
[ $rc -eq 0 ] || { tail -20 $L/go-fixes.log; exit 1; }
log "building api"
sudo docker run --rm -v $S:/src -v $B/cargo:/usr/local/cargo/registry -w /src/api rust:1-bookworm bash -c \
  'apt-get update -qq && apt-get install -y -qq cmake clang >/dev/null && cargo build --release && cp target/release/rlp-api /src/.out-rlp-api' > $L/api-fixes.log 2>&1
rc=$?; [ -f $S/.out-rlp-api ] && sudo mv $S/.out-rlp-api $O/rlp-api && sudo chown $USER $O/rlp-api; log "api rc=$rc"
[ $rc -eq 0 ] || { tail -25 $L/api-fixes.log; exit 1; }
( cd $O && sha256sum rlp-runner rlp-api )
log "verifying the knobs are compiled in"
for k in RLP_INITDISK_MODE RLP_CGROUP_POOL RLP_NEIGH_PERMANENT; do printf "  %-24s runner:%s\n" $k "$(grep -c $k $O/rlp-runner)"; done
printf "  %-24s api:%s\n" RLP_API_LISTEN_BACKLOG "$(grep -c RLP_API_LISTEN_BACKLOG $O/rlp-api)"
