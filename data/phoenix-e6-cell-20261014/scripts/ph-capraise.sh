#!/bin/bash
# Bench-cell-only patch: raise the hard create-pickup cap so a density ladder measures the
# hardware rather than api/src/events/mod.rs:437 (CREATE_MAX_QUEUE_SECS_CAP = 60). The cell then
# honours RLP_CREATE_MAX_QUEUE_SECS up to 900s. Not for the fleet — the 60s cap exists so a
# create with no capacity fails fast with a truthful error.
set -euo pipefail
B=$HOME/rlp-build; S=$B/src; O=$B/out
say() { echo "[$(date -u +%T)] $*"; }
f=$S/api/src/events/mod.rs
grep -q 'CREATE_MAX_QUEUE_SECS_CAP: i64 = 60;' $f && \
  sed -i 's|pub(crate) const CREATE_MAX_QUEUE_SECS_CAP: i64 = 60;|pub(crate) const CREATE_MAX_QUEUE_SECS_CAP: i64 = 900; // BENCH CELL ONLY (was 60): the 60s cap, not the hardware, ends a density ladder|' $f
grep -n 'CREATE_MAX_QUEUE_SECS_CAP: i64' $f
say "rebuilding rlp-api"
sudo docker run --rm -v $S:/src -v $B/cargo:/usr/local/cargo/registry -w /src/api rust:1-bookworm bash -c \
  'apt-get update -qq && apt-get install -y -qq cmake clang >/dev/null && cargo build --release && cp target/release/rlp-api /src/.out-rlp-api' > $B/logs/api-capraise.log 2>&1 \
  || { tail -20 $B/logs/api-capraise.log; exit 1; }
sudo mv $S/.out-rlp-api $O/rlp-api
say "installing and restarting"
sudo systemctl stop rlp-api
sudo install -m 755 $O/rlp-api /opt/rlp/rlp-api
grep -q RLP_CREATE_MAX_QUEUE_SECS /etc/rlp/api.env || echo 'RLP_CREATE_MAX_QUEUE_SECS=600' | sudo tee -a /etc/rlp/api.env >/dev/null
sudo systemctl start rlp-api
for i in $(seq 1 60); do curl -fsS -m2 127.0.0.1:8088/health >/dev/null 2>&1 && break; sleep 2; done
say "api=$(systemctl is-active rlp-api) health=$(curl -s -o /dev/null -w '%{http_code}' 127.0.0.1:8088/health) sha=$(sha256sum /opt/rlp/rlp-api | cut -c1-12)"
echo "$(date -u +%FT%TZ) BENCH PATCH: api CREATE_MAX_QUEUE_SECS_CAP 60 -> 900 (api/src/events/mod.rs), RLP_CREATE_MAX_QUEUE_SECS=600. Revert by rebuilding from a clean tree. Reason: the 60s cap, not the hardware, ended the density ladder at ~4k burst / 6.7k held." | sudo tee -a /etc/rlp/HOSTCHANGES >/dev/null
sudo sed -i 's|^daytona f0611fa13|daytona f0611fa13 [+bench patch: CREATE_MAX_QUEUE_SECS_CAP=900]|' /etc/rlp/BUILD 2>/dev/null || true
