#!/bin/bash
# The eng SDK sends scratch_mib = int(disk)*1024, so any disk < 1 GiB becomes 0 and the API
# substitutes its 1 GiB default. That 1 GiB reservation per sandbox, against 95% of a 7 TB
# filesystem, is what caps this host at 6,743 concurrent sandboxes. Round instead of truncate.
set -euo pipefail
python3 - <<'PY'
from pathlib import Path
p = Path.home() / "rlp/clients/python/src/rlp/daytona.py"
t = p.read_text()
old = 'body["scratch_mib"] = int(r.disk) * 1024'
new = 'body["scratch_mib"] = int(round(float(r.disk) * 1024))'
if old in t:
    p.write_text(t.replace(old, new)); print("sdk patched:", p)
elif new in t: print("sdk already patched")
else:
    import re
    m = [l for l in t.splitlines() if "scratch_mib" in l]
    print("sdk scratch_mib line not recognised:", m)
PY
sudo sed -i 's|^RLP_MAX_LIVE_VMS=.*|RLP_MAX_LIVE_VMS=20000|' /etc/rlp/runner.env
sudo grep -E '^RLP_(MAX_LIVE_VMS|NETNS_POOL|SUBNET_CIDR)=' /etc/rlp/runner.env
echo "$(date -u +%FT%TZ) MAX_LIVE_VMS 8000->20000; harness SDK scratch_mib int()->round() so sub-GiB disks are honoured (1 GiB default reservation capped the host at 6743)" | sudo tee -a /etc/rlp/HOSTCHANGES >/dev/null
sudo systemctl restart rlp-runner
for i in $(seq 1 120); do n=$(sudo ip netns list | wc -l); [ "$n" -ge 6100 ] && break; sleep 5; done
echo "runner=$(systemctl is-active rlp-runner) netns=$(sudo ip netns list | wc -l)"
# verify the reservation is now 64 MiB, not 1 GiB
cd ~/arm64-benchmark-1
export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1; set -a; . ./.env; set +a
uv run python mpfleet.py --target phoenix-e6 --count 4 --procs 2 --output /tmp/scratchcheck.jsonl >/dev/null 2>&1 || true
sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc \
  "select 'live='||(capacity->>'live_vms')||' reserved_scratch_mib='||(capacity->'reserved'->>'ScratchMiB')||' reserved_mem_mib='||(capacity->'reserved'->>'MemMiB') from runners"
