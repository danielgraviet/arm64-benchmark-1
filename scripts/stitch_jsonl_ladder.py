"""Stitch per-level waves from multiple n=200 / -E 8 JSONL files into one ladder.

Same rule on every series (Vera and Phoenix): for each concurrency, prefer a
0-fail wave; if every copy failed, take the newest filename.

Does not invent missing levels. Phoenix has no 264/528/704 today — those stay
absent until you run them.

Usage:
  uv run python scripts/stitch_jsonl_ladder.py
"""

from __future__ import annotations

import json
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"

LEVELS = (1, 8, 22, 44, 88, 132, 176, 264, 352, 528, 704)
REQUIRE_E = 8
REQUIRE_N = 200
REQUIRE_SEED = 42

SERIES = (
    ("agent", "rlp-vera"),
    ("agent", "rlp-phoenix"),
    ("analytics", "rlp-vera"),
    ("analytics", "rlp-phoenix"),
)

SKIP_SUBSTRINGS = ("patched704", "stitched")


def load_file(path: Path) -> tuple[dict, dict[int, list[dict]], dict[int, dict]]:
    meta: dict = {}
    runs: dict[int, list[dict]] = defaultdict(list)
    summaries: dict[int, dict] = {}
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            kind = row.get("type")
            if kind == "meta":
                meta = row
            elif kind == "run":
                runs[int(row["concurrency"])].append(row)
            elif kind == "summary":
                summaries[int(row["concurrency"])] = row
    return meta, runs, summaries


def eligible(path: Path, meta: dict) -> bool:
    if any(s in path.name for s in SKIP_SUBSTRINGS):
        return False
    if meta.get("n") != REQUIRE_N:
        return False
    if meta.get("episodes_per_sandbox") != REQUIRE_E:
        return False
    if meta.get("seed") != REQUIRE_SEED:
        return False
    return True


def pick_waves(benchmark: str, series: str) -> tuple[dict[int, tuple[Path, dict, list[dict], dict]], dict]:
    folder = DATA / benchmark / series
    chosen: dict[int, tuple[Path, dict, list[dict], dict]] = {}
    considered: list[str] = []
    for path in sorted(folder.glob("concurrency_*.jsonl")):
        meta, runs, summaries = load_file(path)
        if not eligible(path, meta):
            continue
        considered.append(path.name)
        for conc, summary in summaries.items():
            if conc not in LEVELS:
                continue
            fails = int(summary.get("failures") or 0)
            prev = chosen.get(conc)
            if prev is None:
                chosen[conc] = (path, meta, runs.get(conc, []), summary)
                continue
            prev_path, _, _, prev_sum = prev
            prev_fails = int(prev_sum.get("failures") or 0)
            # 0-fail always beats a failing wave. If both fail or both succeed,
            # take the newer filename (SMT ladders sort last).
            better = False
            if fails == 0 and prev_fails > 0:
                better = True
            elif fails > 0 and prev_fails == 0:
                better = False
            elif path.name > prev_path.name:
                better = True
            if better:
                chosen[conc] = (path, meta, runs.get(conc, []), summary)
    note = {
        "considered_files": considered,
        "missing_levels": [c for c in LEVELS if c not in chosen],
        "picks": {
            str(c): {
                "file": p.name,
                "failures": int(s.get("failures") or 0),
                "runs": s.get("runs"),
                "throughput_per_sec": s.get("throughput_per_sec"),
            }
            for c, (p, _, _, s) in sorted(chosen.items())
        },
    }
    return chosen, note


def write_stitched(benchmark: str, series: str) -> Path | None:
    chosen, note = pick_waves(benchmark, series)
    if not chosen:
        print(f"skip {benchmark}/{series}: no eligible files")
        return None
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    # Name sorts after 20260825_HHMMSS so eda.py newest-by-name picks this.
    out = DATA / benchmark / series / f"concurrency_20260825_patched704_n{REQUIRE_N}.jsonl"
    first_meta = next(iter(chosen.values()))[1]
    meta = {
        **{k: v for k, v in first_meta.items() if k != "type"},
        "type": "meta",
        "stitched": True,
        "stitch_rule": (
            f"Per-level splice of -E {REQUIRE_E} --n {REQUIRE_N} --seed {REQUIRE_SEED}; "
            "0-fail wave wins; otherwise newest filename. Missing levels not invented."
        ),
        "stitch": note,
        "stitch_written_utc": stamp,
    }
    with out.open("w", encoding="utf-8") as f:
        f.write(json.dumps(meta, separators=(",", ":")) + "\n")
        for conc in LEVELS:
            if conc not in chosen:
                continue
            _, _, run_rows, summary = chosen[conc]
            for row in run_rows:
                f.write(json.dumps(row, separators=(",", ":")) + "\n")
            f.write(json.dumps(summary, separators=(",", ":")) + "\n")
    missing = note["missing_levels"]
    print(f"wrote {out.relative_to(ROOT)}")
    print(f"  levels={sorted(chosen)} missing={missing}")
    for c, pick in note["picks"].items():
        print(f"    c={c:>3} fails={pick['failures']:<4} {pick['file']}")
    return out


def main() -> None:
    for benchmark, series in SERIES:
        write_stitched(benchmark, series)
        print()


if __name__ == "__main__":
    main()
