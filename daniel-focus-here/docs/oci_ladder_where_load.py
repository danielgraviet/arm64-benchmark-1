"""Numbers for the OCI ladder "where the time goes" figures.

OCI file is the full n=45 ladder pulled on 2026-10-12.
Onsite file is the published Vera dense ladder.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

DOCS = Path(__file__).resolve().parent
FOCUS = DOCS.parent

OCI_LADDER = (
    FOCUS / "oci-vera-jsonl" / "concurrency_20261012_174542_n45.jsonl"
)
# Reruns that replace one rung of the full ladder.
OCI_PATCHES = (
    FOCUS / "oci-vera-jsonl" / "concurrency_20261012_233215_n45.jsonl",  # 44 on cores 0-43
    FOCUS / "oci-vera-jsonl" / "concurrency_20261012_234300_n45.jsonl",  # 88 on cores 0-65
    FOCUS / "oci-vera-jsonl" / "concurrency_20261012_235151_n45.jsonl",  # 176 on cores 0-87,176-210
)
ONSITE_LADDER = (
    FOCUS / "vera-jsonl" / "vera_graph_source_dense2k_20260906_183636.jsonl"
)
ZEN5_LADDER = (
    FOCUS / "zen5-9575f-jsonl" / "concurrency_20261012_191603_n45.jsonl"
)


@dataclass(frozen=True)
class LadderLevel:
    concurrency: int
    runs: int
    failures: int
    checksum_ok: bool
    throughput_per_sec: float
    p50_duration_ms: float
    create_wall_s: float
    exec_wall_s: float
    delete_wall_s: float

    @property
    def wave_s(self) -> float:
        return self.create_wall_s + self.exec_wall_s + self.delete_wall_s

    @property
    def jobs_share(self) -> float:
        if self.wave_s <= 0:
            return 0.0
        return self.exec_wall_s / self.wave_s


def load_levels(path: Path) -> list[LadderLevel]:
    levels: list[LadderLevel] = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            row = json.loads(line)
            if row.get("type") != "summary":
                continue
            levels.append(
                LadderLevel(
                    concurrency=int(row["concurrency"]),
                    runs=int(row["runs"]),
                    failures=int(row.get("failures") or 0),
                    checksum_ok=bool(row.get("checksum_ok")),
                    throughput_per_sec=float(row["throughput_per_sec"]),
                    p50_duration_ms=float(row["p50_duration_ms"]),
                    create_wall_s=float(row["create_wall_s"]),
                    exec_wall_s=float(row["exec_wall_s"]),
                    delete_wall_s=float(row["delete_wall_s"]),
                )
            )
    if not levels:
        raise ValueError(f"no summary rows in {path}")
    return levels


def load_oci() -> list[LadderLevel]:
    levels = load_levels(OCI_LADDER)
    patch: dict[int, LadderLevel] = {}
    for path in OCI_PATCHES:
        for level in load_levels(path):
            patch[level.concurrency] = level
    return [patch.get(level.concurrency, level) for level in levels]


def load_pair() -> tuple[list[LadderLevel], list[LadderLevel], list[LadderLevel]]:
    return load_oci(), load_levels(ONSITE_LADDER), load_levels(ZEN5_LADDER)
