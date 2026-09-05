"""Marketing charts for nvidia-agent-brief.md (pinned JSONL, merged ladders).

Base burst ladder (1 GiB, c=1..704) plus max-pack extension (512 MiB, c=880..2784).
Vera max-pack is merged today; Zen5 max-pack is appended when its JSONL exists.

Usage:
  uv run python scripts/nvidia_brief_agent_charts.py
"""

from __future__ import annotations

import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from eda import completed_throughput, load_jsonl, percentile_duration  # noqa: E402

OUT = ROOT / "eda_output" / "nvidia-brief-agent"

# Pinned paths — do not use discover_datasets / newest-file heuristics.
BASE: dict[str, Path] = {
    "vera": ROOT
    / "data/agent/rlp-vera-c0p125-max1/concurrency_20260826_005637_n50.jsonl",
    "zen5": ROOT
    / "data/agent/rlp-phoenix-c0p125-max1/concurrency_20260826_012143_n50.jsonl",
}
MAXPACK: dict[str, Path] = {
    "vera": ROOT
    / "data/agent/rlp-vera-c0p125-max1-m512/concurrency_20260826_230252_n50.jsonl",
    "zen5": ROOT
    / "data/agent/rlp-phoenix-c0p125-max1-m512/concurrency_20260827_002721_n50.jsonl",
}
# Phoenix matched Vera m512 ladder (704–2784, 512 MiB). Post-ARP-fix rerun.
MAXPACK_ZEN5 = ROOT / (
    "data/agent/rlp-phoenix-c0p125-max1-m512/concurrency_20260828_153136_n50.jsonl"
)
OUT_ZEN5_MAXPACK = ROOT / "eda_output" / "nvidia-brief-agent-zen5-maxpack"

SERIES = [
    ("vera", "daytona-vera", "#76B900"),
    ("zen5", "daytona-zen5", "#7D7D7D"),
]

SPLIT_AT = 704  # base ladder tops out here; max-pack adds rungs above.
DURATION_NOTE = (
    "duration_ms is in-sandbox CPU/IO; compare this for chip claims, not wall latency_ms"
)
TPUT_NOTE = "Throughput = completed runs / exec wall"


def merge_ladders(
    base: Path,
    extend: Path | None,
    *,
    extend_from: int = SPLIT_AT + 1,
) -> tuple[list[dict], list[dict]]:
    """Base JSONL below ``extend_from``; append extend levels at ``extend_from`` and above."""
    _meta, base_runs, base_summaries = load_jsonl(base)
    merged_runs = [r for r in base_runs if int(r["concurrency"]) < extend_from]
    merged_summaries = [
        s for s in base_summaries if int(s["concurrency"]) < extend_from
    ]
    if extend is not None and extend.is_file():
        _meta2, ext_runs, ext_summaries = load_jsonl(extend)
        for s in ext_summaries:
            level = int(s["concurrency"])
            if level < extend_from:
                continue
            merged_summaries = [
                x for x in merged_summaries if int(x["concurrency"]) != level
            ]
            merged_runs = [r for r in merged_runs if int(r["concurrency"]) != level]
            merged_summaries.append(s)
            merged_runs.extend(
                r for r in ext_runs if int(r["concurrency"]) == level
            )
    merged_summaries.sort(key=lambda s: int(s["concurrency"]))
    return merged_runs, merged_summaries


def all_levels(loaded: dict[str, tuple[list[dict], list[dict]]]) -> list[int]:
    return sorted(
        {int(s["concurrency"]) for _, summaries in loaded.values() for s in summaries}
    )


def p50_duration_ms(runs: list[dict], summary: dict) -> float:
    dur = summary.get("p50_duration_ms")
    if dur is not None:
        return float(dur)
    return percentile_duration(runs, int(summary["concurrency"]), 50)


def load_merged(
    *,
    zen5_maxpack: Path | None = None,
    zen5_extend_from: int = SPLIT_AT + 1,
) -> dict[str, tuple[list[dict], list[dict]]]:
    loaded: dict[str, tuple[list[dict], list[dict]]] = {}
    for key, base_path in BASE.items():
        ext_path = MAXPACK.get(key)
        if key == "zen5" and zen5_maxpack is not None:
            ext_path = zen5_maxpack
        if ext_path is not None and not ext_path.is_file():
            ext_path = None
        extend_from = zen5_extend_from if key == "zen5" else SPLIT_AT + 1
        loaded[key] = merge_ladders(base_path, ext_path, extend_from=extend_from)
        n_levels = len(loaded[key][1])
        ext_note = " + max-pack" if ext_path else ""
        print(f"{key}: {n_levels} levels{ext_note}")
    return loaded


def plot_throughput(
    loaded: dict[str, tuple[list[dict], list[dict]]],
    out_dir: Path,
) -> None:
    fig, ax = plt.subplots(figsize=(13, 5.5))
    labels = {k: lab for k, lab, _ in SERIES}
    colors = {k: col for k, _, col in SERIES}

    for key, (_, summaries) in loaded.items():
        levels = [int(s["concurrency"]) for s in summaries]
        tput = [completed_throughput(s, series=key) for s in summaries]
        ax.plot(
            levels,
            tput,
            marker="o",
            linewidth=2.2,
            label=labels[key],
            color=colors[key],
        )
        for level, value in zip(levels, tput):
            ax.annotate(
                f"{value:.1f}",
                (level, value),
                textcoords="offset points",
                xytext=(0, 8),
                ha="center",
                fontsize=7,
            )

    levels = all_levels(loaded)
    ax.set_xlabel("Concurrency level")
    ax.set_ylabel("Throughput (completed runs / sec)")
    ax.set_title(
        "Agent task — Daytona Vera versus Daytona zen5\n"
        "Throughput vs concurrency (higher is better)",
        fontsize=13,
    )
    ax.set_xticks(levels)
    ax.set_xticklabels([str(level) for level in levels], rotation=45, ha="right")
    ax.legend(loc="upper left", frameon=False)
    ax.grid(True, alpha=0.3)
    fig.text(0.5, 0.01, TPUT_NOTE, ha="center", fontsize=8, style="italic")
    fig.tight_layout()
    fig.subplots_adjust(bottom=0.22)
    fig.savefig(out_dir / "throughput_vs_concurrency.png", dpi=180)
    plt.close(fig)


def plot_duration(
    loaded: dict[str, tuple[list[dict], list[dict]]],
    out_dir: Path,
) -> None:
    fig, ax = plt.subplots(figsize=(13, 5.5))
    labels = {k: lab for k, lab, _ in SERIES}
    colors = {k: col for k, _, col in SERIES}

    for key, (runs, summaries) in loaded.items():
        levels: list[int] = []
        durs: list[float] = []
        for s in summaries:
            dur = p50_duration_ms(runs, s)
            if not dur:
                continue
            levels.append(int(s["concurrency"]))
            durs.append(dur)
        ax.plot(
            levels,
            durs,
            marker="o",
            linewidth=2.2,
            label=labels[key],
            color=colors[key],
        )
        for level, value in zip(levels, durs):
            ax.annotate(
                f"{value:.0f}",
                (level, value),
                textcoords="offset points",
                xytext=(0, 8),
                ha="center",
                fontsize=7,
            )

    levels = all_levels(loaded)
    ax.set_xlabel("Concurrency level")
    ax.set_ylabel("p50 duration_ms (in-sandbox work)")
    ax.set_title(
        "Agent task — Daytona Vera versus Daytona zen5\n"
        "In-sandbox p50 duration vs concurrency (lower is better)",
        fontsize=13,
    )
    ax.set_xticks(levels)
    ax.set_xticklabels([str(level) for level in levels], rotation=45, ha="right")
    ax.legend(loc="upper left", frameon=False)
    ax.grid(True, alpha=0.3)
    fig.text(0.5, 0.01, DURATION_NOTE, ha="center", fontsize=8, style="italic")
    fig.tight_layout()
    fig.subplots_adjust(bottom=0.22)
    fig.savefig(out_dir / "duration_vs_concurrency.png", dpi=180)
    plt.close(fig)


def write_charts(
    loaded: dict[str, tuple[list[dict], list[dict]]],
    out_dir: Path,
) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    plot_throughput(loaded, out_dir)
    plot_duration(loaded, out_dir)
    print(f"Wrote charts to {out_dir}/")
    for path in sorted(out_dir.glob("*.png")):
        print(f"  - {path.name}")


def main() -> None:
    print("Brief charts (Vera max-pack; Zen5 1 GiB through 704):")
    brief_loaded = load_merged()
    write_charts(brief_loaded, OUT)

    if MAXPACK_ZEN5.is_file():
        print("Zen5 max-pack charts (Vera unchanged; Zen5 m512 through latest run):")
        zen5_loaded = load_merged(zen5_maxpack=MAXPACK_ZEN5, zen5_extend_from=SPLIT_AT + 1)
        write_charts(zen5_loaded, OUT_ZEN5_MAXPACK)
    else:
        print(f"Skipping Zen5 max-pack charts — not found: {MAXPACK_ZEN5}")


if __name__ == "__main__":
    main()
