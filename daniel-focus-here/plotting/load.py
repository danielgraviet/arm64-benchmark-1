"""Load summary / ready rows from focus-pack JSONL files."""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any


def load_dense_summaries(path: Path) -> dict[int, dict[str, Any]]:
    """concurrency → summary row (last summary wins if duplicates)."""
    out: dict[int, dict[str, Any]] = {}
    with path.open() as fh:
        for line in fh:
            if not line.strip():
                continue
            row = json.loads(line)
            if row.get("type") != "summary":
                continue
            conc = row.get("concurrency")
            if conc is None:
                continue
            out[int(conc)] = row
    return out


def load_ready_wall(path: Path) -> float:
    """ready_wall_s from a create-ready JSONL, or from its .meta.json sidecar."""
    if path.is_file() and path.stat().st_size > 0:
        with path.open() as fh:
            for line in fh:
                if not line.strip():
                    continue
                row = json.loads(line)
                if row.get("type") == "summary" and row.get("ready_wall_s") is not None:
                    return float(row["ready_wall_s"])
    sidecar = path.with_suffix(".meta.json")
    if sidecar.is_file():
        blob = json.loads(sidecar.read_text())
        summary = blob.get("summary") if isinstance(blob, dict) else None
        if isinstance(summary, dict) and summary.get("ready_wall_s") is not None:
            return float(summary["ready_wall_s"])
    raise RuntimeError(f"no ready_wall_s in {path}")


def load_ready_times(path: Path) -> list[float]:
    """Seconds for successful create-ready repeats (skips failure rows)."""
    times: list[float] = []
    with path.open() as fh:
        for line in fh:
            if not line.strip():
                continue
            row = json.loads(line)
            if row.get("type") == "failure":
                continue
            if row.get("type") == "stats":
                continue
            t = row.get("total_time_s") or row.get("ready_wall_s")
            if t is None:
                continue
            times.append(float(t))
    return times


def mean_std(values: list[float]) -> tuple[float, float]:
    if not values:
        return 0.0, 0.0
    mean = sum(values) / len(values)
    if len(values) == 1:
        return mean, 0.0
    var = sum((x - mean) ** 2 for x in values) / (len(values) - 1)
    return mean, math.sqrt(var)


def p50_duration_ms(summary: dict[str, Any]) -> float:
    for key in ("p50_duration_ms", "p50_ms"):
        if summary.get(key) is not None:
            return float(summary[key])
    return 0.0
