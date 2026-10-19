#!/usr/bin/env python3
"""Recompute headline figures from pinned JSONL. Read-only.

    uv run python daniel-focus-here/plotting/pin_headline.py
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

FOCUS = Path(__file__).resolve().parent.parent
if str(FOCUS) not in sys.path:
    sys.path.insert(0, str(FOCUS))

from plotting.load import load_dense_summaries, mean_std, p50_duration_ms  # noqa: E402
from plotting import sources as src  # noqa: E402



def _t_crit_95(n: int) -> float:
    # Two-sided Student t, df = n-1, for the repeat counts we actually have.
    table = {2: 12.706, 3: 4.303, 4: 3.182, 5: 2.776}
    if n not in table:
        raise ValueError(f"no t critical for n={n}")
    return table[n]


def ci95(values: list[float]) -> tuple[float, float, float]:
    mean, std = mean_std(values)
    if len(values) < 2:
        return mean, std, 0.0
    half = _t_crit_95(len(values)) * std / math.sqrt(len(values))
    return mean, std, half


def load_summary(path: Path) -> dict:
    if path.is_file() and path.stat().st_size > 0:
        summary = None
        with path.open() as fh:
            for line in fh:
                if not line.strip():
                    continue
                row = json.loads(line)
                if row.get("type") == "summary":
                    summary = row
        if summary is not None:
            return summary
    # Two Vera 1000 repeats kept the summary in a sidecar beside an empty jsonl.
    sidecar = path.with_suffix(".meta.json")
    if sidecar.is_file():
        blob = json.loads(sidecar.read_text())
        summary = blob.get("summary")
        if isinstance(summary, dict):
            return summary
    raise RuntimeError(f"no summary in {path}")


def load_meta(path: Path) -> dict:
    with path.open() as fh:
        for line in fh:
            if not line.strip():
                continue
            row = json.loads(line)
            if row.get("type") == "meta":
                return row
    raise RuntimeError(f"no meta in {path}")


def print_ready(title: str, groups: dict[str, list[Path]]) -> None:
    print(f"\n== {title} ==")
    for key, paths in groups.items():
        walls = []
        print(f"  {key}")
        for path in paths:
            row = load_summary(path)
            wall = float(row["ready_wall_s"])
            walls.append(wall)
            print(
                f"    {path.name}: ok={row.get('ok')} failed={row.get('failed')} "
                f"ready_wall_s={wall:.3f} status={row.get('status')}"
            )
        mean, std, half = ci95(walls)
        print(
            f"    n={len(walls)} mean={mean:.2f} std={std:.2f} "
            f"ci95=±{half:.2f} min={min(walls):.2f} max={max(walls):.2f}"
        )


def print_stub(title: str, path: Path) -> None:
    print(f"\n== stub {title}: {path.name} ==")
    times = []
    with path.open() as fh:
        for line in fh:
            if not line.strip():
                continue
            row = json.loads(line)
            kind = row.get("type")
            if kind == "ready":
                t = float(row["total_time_s"])
                times.append(t)
                print(f"  ready {t:.3f} source={row.get('source')}")
            elif kind == "failure":
                print(f"  failure {row.get('failure')}")
            elif kind == "stats":
                print(
                    f"  stats n={row.get('n')} mean={row.get('mean_s')} "
                    f"ci95={row.get('ci95_s')}"
                )
    if times:
        mean, std, half = ci95(times)
        print(f"  recomputed n={len(times)} mean={mean:.2f} std={std:.2f} ci95=±{half:.2f}")


def main() -> None:
    print("== dense meta ==")
    for key, path in src.DENSE.items():
        meta = load_meta(path)
        print(
            f"  {key}: target={meta.get('target')} n={meta.get('n')} "
            f"E={meta.get('episodes_per_sandbox')} cpu={meta.get('rlp_cpu')} "
            f"cpu_max={meta.get('rlp_cpu_max')} mem={meta.get('rlp_memory')} "
            f"mem_max={meta.get('rlp_memory_max')} hold={meta.get('hold_then_exec')} "
            f"client={meta.get('client_host')} "
            f"http={meta.get('rlp_client_tuning', {}).get('http_max_connections')}"
        )

    print("\n== dense summaries ==")
    for key, path in src.DENSE.items():
        rows = load_dense_summaries(path)
        print(f"  {key} levels={sorted(rows)}")
        peak_c = max(rows, key=lambda c: float(rows[c].get("throughput_per_sec") or 0))
        peak = float(rows[peak_c]["throughput_per_sec"])
        print(f"    peak {peak:.2f} jobs/s at {peak_c}")
        for c in sorted(rows):
            row = rows[c]
            print(
                f"    c={c} runs={row.get('runs')} fail={row.get('failures')} "
                f"tput={float(row['throughput_per_sec']):.2f} "
                f"p50_s={p50_duration_ms(row) / 1000:.1f} "
                f"checksum_ok={row.get('checksum_ok')} "
                f"exec_wall_s={row.get('exec_wall_s')}"
            )

    for key, path in src.READY_1K.items():
        print_stub(f"1k {key}", path)
    for key, path in src.READY_2K.items():
        print_stub(f"2k {key}", path)

    print_ready("create-ready 1000 raw", src.READY_1K_RUNS)
    print_ready("create-ready 2000 raw", src.READY_2K_RUNS)


if __name__ == "__main__":
    main()
