#!/usr/bin/env bash
# Raise create-admission knobs on the epyc9755 cell for dense2k hold-then-exec.
# Requires sudo. Restarts rlp-runner so JobConsumer CreateOrUpdate picks up
# RLP_VM_MAXACK / RLP_VM_CONCURRENCY.
set -euo pipefail

CONC="${RLP_VM_CONCURRENCY:-512}"
MAXACK="${RLP_VM_MAXACK:-2048}"
STOP_CONC="${RLP_STOP_CONCURRENCY:-512}"

echo "=== before ==="
sudo grep -E "^(RLP_VM_CONCURRENCY|RLP_VM_MAXACK|RLP_STOP_CONCURRENCY)=" /etc/rlp/runner.env || true

sudo cp -a /etc/rlp/runner.env /etc/rlp/runner.env.bak-pre-dense2k-tune

sudo python3 - <<PY
from pathlib import Path
p = Path("/etc/rlp/runner.env")
want = {
    "RLP_VM_CONCURRENCY": "${CONC}",
    "RLP_VM_MAXACK": "${MAXACK}",
    "RLP_STOP_CONCURRENCY": "${STOP_CONC}",
}
lines = p.read_text().splitlines(True)
out = []
seen = set()
for line in lines:
    if not line.strip() or line.lstrip().startswith("#") or "=" not in line:
        out.append(line)
        continue
    k, _, _ = line.partition("=")
    if k in want:
        out.append(f"{k}={want[k]}\n")
        seen.add(k)
    else:
        out.append(line)
for k, v in want.items():
    if k not in seen:
        out.append(f"{k}={v}\n")
p.write_text("".join(out))
print("wrote", p)
PY

echo "=== after ==="
sudo grep -E "^(RLP_VM_CONCURRENCY|RLP_VM_MAXACK|RLP_STOP_CONCURRENCY)=" /etc/rlp/runner.env

echo "=== restart rlp-runner ==="
sudo systemctl restart rlp-runner
sleep 4
systemctl is-active rlp-runner
curl -fsS http://127.0.0.1:8088/health
echo
echo "tuned: VM_CONCURRENCY=${CONC} VM_MAXACK=${MAXACK} STOP_CONCURRENCY=${STOP_CONC}"
