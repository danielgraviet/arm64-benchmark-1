"""Charts for nvidia-agent-brief-704-zen5/ — Vera vs Zen 5 SKUs through c=704.

Three-way Zen 5 compare on the same agent ladder:
  - Phoenix (us-phoenix-1): Turin 9J45 — high core-count SKU
  - Redswitches: EPYC 9575F — high-frequency SKU

Vera is included as the NVIDIA baseline. Base ladder only (no max-pack above 704).

Usage:
  uv run python scripts/nvidia_brief_704_zen5_charts.py

Regenerate after the redswitches ladder finishes:
  data/agent/rlp-redswitches-c0p125-max1/concurrency_20260828_183551_n50.jsonl
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from eda import completed_throughput, load_jsonl, percentile_duration  # noqa: E402
from scripts.nvidia_brief_agent_charts import p50_duration_ms  # noqa: E402

OUT = ROOT / "nvidia-agent-brief-704-zen5"
MAX_CONCURRENCY = 704

# Pinned JSONL — update redswitches path when the ladder run completes.
PINS: dict[str, Path] = {
    "vera": ROOT
    / "data/agent/rlp-vera-c0p125-max1/concurrency_20260826_005637_n50.jsonl",
    "phoenix": ROOT
    / "data/agent/rlp-phoenix-c0p125-max1/concurrency_20260826_012143_n50.jsonl",
    "redswitches": ROOT
    / "data/agent/rlp-redswitches-c0p125-max1/concurrency_20260828_183551_n50.jsonl",
}

SERIES: list[tuple[str, str, str]] = [
    ("vera", "Vera", "#76B900"),
    ("phoenix", "Zen 5 Turin · 9J45 (Phoenix)", "#7D7D7D"),
    ("redswitches", "Zen 5 · 9575F (Redswitches)", "#C41E3A"),
]

DURATION_NOTE = (
    "p50 duration_ms is in-sandbox work only (excludes create/delete and client RTT)"
)
TPUT_NOTE = "Throughput = completed runs / exec wall"


def load_series() -> dict[str, tuple[list[dict], list[dict]]]:
    loaded: dict[str, tuple[list[dict], list[dict]]] = {}
    for key, path in PINS.items():
        if not path.is_file():
            print(f"SKIP {key}: missing {path.relative_to(ROOT)}")
            continue
        _meta, runs, summaries = load_jsonl(path)
        summaries = [
            s for s in summaries if int(s["concurrency"]) <= MAX_CONCURRENCY
        ]
        levels = {int(s["concurrency"]) for s in summaries}
        runs = [r for r in runs if int(r["concurrency"]) in levels]
        loaded[key] = (runs, summaries)
        level_list = sorted(levels)
        fails = sum(int(s.get("failures", 0)) for s in summaries)
        print(
            f"{key}: {len(level_list)} levels "
            f"(c={level_list[0]}..{level_list[-1]}) failures={fails}"
        )
    return loaded


def all_levels(loaded: dict[str, tuple[list[dict], list[dict]]]) -> list[int]:
    return sorted(
        {int(s["concurrency"]) for _, summaries in loaded.values() for s in summaries}
    )


def plot_throughput(
    loaded: dict[str, tuple[list[dict], list[dict]]],
    out_dir: Path,
) -> None:
    labels = {k: lab for k, lab, _ in SERIES}
    colors = {k: col for k, _, col in SERIES}
    fig, ax = plt.subplots(figsize=(13, 5.5))

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
    ax.legend(loc="upper left", frameon=False, fontsize=9)
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
    labels = {k: lab for k, lab, _ in SERIES}
    colors = {k: col for k, _, col in SERIES}
    fig, ax = plt.subplots(figsize=(13, 5.5))

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
    ax.legend(loc="upper left", frameon=False, fontsize=9)
    ax.grid(True, alpha=0.3)
    fig.text(0.5, 0.01, DURATION_NOTE, ha="center", fontsize=8, style="italic")
    fig.tight_layout()
    fig.subplots_adjust(bottom=0.22)
    fig.savefig(out_dir / "duration_vs_concurrency.png", dpi=180)
    plt.close(fig)


def write_headline_table(
    loaded: dict[str, tuple[list[dict], list[dict]]],
    out_dir: Path,
) -> None:
    """Markdown table for key rungs (c=1, 88, 176, 352, 704)."""
    keys = [k for k, _, _ in SERIES if k in loaded]
    pick = [1, 88, 176, 352, 704]
    lines = [
        "| Concurrency | "
        + " | ".join(f"{k} p50 dur (ms)" for k in keys)
        + " |",
        "|------------:|" + "|".join(["---:"] * len(keys)) + "|",
    ]
    for c in pick:
        cells: list[str] = []
        for key in keys:
            runs, summaries = loaded[key]
            match = next((s for s in summaries if int(s["concurrency"]) == c), None)
            if match is None:
                cells.append("—")
            else:
                cells.append(f"{p50_duration_ms(runs, match):,.0f}")
        lines.append(f"| {c} | " + " | ".join(cells) + " |")
    (out_dir / "headline_table.md").write_text("\n".join(lines) + "\n")


def write_sources(out_dir: Path, loaded: dict[str, tuple[list[dict], list[dict]]]) -> None:
    meta_lines = ["# Pinned source JSONL\n"]
    for key, path in PINS.items():
        status = "present" if key in loaded else "missing"
        rel = path.relative_to(ROOT)
        meta_lines.append(f"- **{key}** ({status}): `{rel}`")
    (out_dir / "sources.md").write_text("\n".join(meta_lines) + "\n")


def main() -> None:
    loaded = load_series()
    if not loaded:
        raise SystemExit("No JSONL files found — check PINS in this script.")
    OUT.mkdir(parents=True, exist_ok=True)
    plot_throughput(loaded, OUT)
    plot_duration(loaded, OUT)
    write_headline_table(loaded, OUT)
    write_sources(OUT, loaded)
    print(f"Wrote charts and tables to {OUT}/")


if __name__ == "__main__":
    main()
