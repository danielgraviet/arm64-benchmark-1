#!/bin/bash
# Register phoenix-e6 as a first-class target across the harness scripts, and install
# the methodology tools (mpfleet.py multi-process client, bench-preflight.sh).
set -euo pipefail
cd ~/arm64-benchmark-1
python3 - <<'PY'
import pathlib, re
T = "phoenix-e6"
changed = []

# 1) every argparse target choice list
for p in pathlib.Path("scripts").rglob("*.py"):
    s = p.read_text()
    if '"epyc9575"' in s and f'"{T}"' not in s:
        s2 = s.replace('("vera", "redswitches", "epyc9755", "epyc9575")',
                       f'("vera", "redswitches", "epyc9755", "epyc9575", "{T}")')
        s2 = s2.replace('choices=("vera", "redswitches", "epyc9755", "epyc9575"),',
                        f'choices=("vera", "redswitches", "epyc9755", "epyc9575", "{T}"),')
        if s2 != s:
            p.write_text(s2); changed.append(str(p))

# 2) run_create_ready.sh output dir
p = pathlib.Path("scripts/host/run_create_ready.sh"); s = p.read_text()
if T not in s:
    s = s.replace('  epyc9755) OUT_DIR="daniel-focus-here/zen5-9755-jsonl" ;;',
                  '  epyc9755) OUT_DIR="daniel-focus-here/zen5-9755-jsonl" ;;\n'
                  f'  {T}) OUT_DIR="results/phoenix-e6-jsonl" ;;')
    p.write_text(s); changed.append(str(p))

print("patched:", ", ".join(changed) if changed else "nothing (already done)")
PY
mkdir -p results/phoenix-e6-jsonl docs scripts/host
[ -f /tmp/mpfleet.py ] && cp /tmp/mpfleet.py mpfleet.py && echo "installed mpfleet.py"
[ -f /tmp/bench-preflight.sh ] && cp /tmp/bench-preflight.sh scripts/host/bench-preflight.sh && chmod +x scripts/host/bench-preflight.sh && echo "installed scripts/host/bench-preflight.sh"
[ -f /tmp/benchmark-methodology.md ] && cp /tmp/benchmark-methodology.md docs/benchmark-methodology.md && echo "installed docs/benchmark-methodology.md"
grep -rn "phoenix-e6" scripts/rlp_light_create_fleet.py scripts/host/run_create_ready.sh | head
