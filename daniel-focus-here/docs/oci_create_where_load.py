"""Numbers for the OCI create "where the time goes" figures.

The three runs are the steady thousand-sandbox creates on 2026-10-12.
Earlier runs in the same folder include restart tax and are not part of this note.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

DOCS = Path(__file__).resolve().parent
JSONL_DIR = DOCS.parent / "oci-vera-jsonl"

RUNS = (
    "vera_create_ready_1000_20261012_161429.jsonl",
    "vera_create_ready_1000_20261012_161500.jsonl",
    "vera_create_ready_1000_20261012_161549.jsonl",
)


def percentile(values: list[float], q: float) -> float:
    ordered = sorted(values)
    if not ordered:
        raise ValueError("empty sample")
    index = int(round((q / 100.0) * (len(ordered) - 1)))
    return float(ordered[index])


@dataclass(frozen=True)
class SandboxClock:
    post_s: float
    wait_s: float
    create_s: float
    probe_s: float


@dataclass(frozen=True)
class CreateRun:
    path: Path
    wall_s: float
    boot_p50_ms: float
    scratch_p50_ms: float
    memory_p50_ms: float
    vm_start_p50_ms: float
    guest_ready_p50_ms: float
    first: SandboxClock
    typical_post_s: float
    typical_wait_s: float
    typical_create_s: float
    typical_probe_s: float
    last: SandboxClock
    last_start_ms: float


def _clock(row: dict) -> SandboxClock:
    return SandboxClock(
        post_s=float(row["post_s"]),
        wait_s=float(row["wait_s"]),
        create_s=float(row["create_s"]),
        probe_s=float(row.get("probe_s") or 0.0),
    )


def load_run(path: Path) -> CreateRun:
    sandboxes: list[dict] = []
    summary: dict | None = None
    wall_share: dict | None = None
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            row = json.loads(line)
            kind = row.get("type")
            if kind == "sandbox" and row.get("status") == "ok":
                sandboxes.append(row)
            elif kind == "summary":
                summary = row
            elif kind == "wall_share":
                wall_share = row
    if not sandboxes or summary is None or wall_share is None:
        raise ValueError(f"{path.name} is missing sandbox, summary, or wall_share rows")

    phases = wall_share["phase_p50_ms"]
    last_runner = (wall_share.get("last") or {}).get("runner") or {}
    return CreateRun(
        path=path,
        wall_s=float(summary["ready_wall_s"]),
        boot_p50_ms=float(wall_share["runner_boot_p50_ms"]),
        scratch_p50_ms=float(phases["scratch_cp_ms"]),
        memory_p50_ms=float(phases["load_ms"]),
        vm_start_p50_ms=float(phases["fc_start_ms"]),
        guest_ready_p50_ms=float(phases["toolbox_wait_ms"]),
        first=_clock(min(sandboxes, key=lambda row: float(row["create_s"]))),
        typical_post_s=percentile([float(row["post_s"]) for row in sandboxes], 50),
        typical_wait_s=percentile([float(row["wait_s"]) for row in sandboxes], 50),
        typical_create_s=percentile([float(row["create_s"]) for row in sandboxes], 50),
        typical_probe_s=percentile([float(row.get("probe_s") or 0.0) for row in sandboxes], 50),
        last=_clock(max(sandboxes, key=lambda row: float(row["create_s"]))),
        last_start_ms=float(last_runner.get("total_ms") or wall_share["runner_boot_p50_ms"]),
    )


def load_runs(jsonl_dir: Path | None = None) -> list[CreateRun]:
    root = jsonl_dir or JSONL_DIR
    return [load_run(root / name) for name in RUNS]
