"""NVIDIA brief charts from pinned JSONL paths (never 'newest file').

Usage:
  uv run python scripts/nvidia_brief_charts.py
"""

from __future__ import annotations

import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from eda import load_jsonl, mean_duration  # noqa: E402

OUT = ROOT / "eda_output" / "nvidia-brief"

# Pinned 0-fail pairs from analysis.md. Do not replace with glob newest.
PINS: dict[str, dict[str, str]] = {
    "agent": {
        "Vera": "data/agent/rlp-vera/concurrency_20260821_161503_n200.jsonl",
        "Zen 5": "data/agent/rlp-phoenix/concurrency_20260821_164629_n200.jsonl",
    },
    "disk": {
        "Vera": "data/disk/rlp-vera/concurrency_20260821_162121_n128.jsonl",
        "Zen 5": "data/disk/rlp-phoenix/concurrency_20260821_165436_n128.jsonl",
    },
    "analytics": {
        "Vera": "data/analytics/rlp-vera/concurrency_20260821_162249_n200.jsonl",
        "Zen 5": "data/analytics/rlp-phoenix/concurrency_20260821_171146_n200.jsonl",
    },
    "rl": {
        "Vera": "data/rl/rlp-vera/concurrency_20260821_154514_n5000.jsonl",
        "Zen 5": "data/rl/rlp-phoenix/concurrency_20260821_163715_n5000.jsonl",
    },
}

LEVELS = (1, 8, 22, 44, 88, 132, 176)
COLORS = {"Vera": "#76B900", "Zen 5": "#7D7D7D"}  # NVIDIA green; gray for Zen 5
DURATION_NOTE = (
    "Time per job is in-sandbox duration (chip). Starting or stopping the sandbox "
    "is not included. Lower is faster."
)
TPUT_NOTE = (
    "Jobs per second is how many jobs the wave finished, divided by wall-clock time. "
    "Use time per job for chip speed."
)


def _load_pin(rel: str) -> tuple[list[dict], list[dict]]:
    path = ROOT / rel
    if not path.is_file():
        raise FileNotFoundError(path)
    _meta, runs, summaries = load_jsonl(path)
    return runs, summaries


def _mean_duration_s(runs: list[dict], conc: int) -> float:
    return mean_duration(runs, conc) / 1000.0


def _tput(summaries: list[dict], conc: int) -> float:
    by = {s["concurrency"]: s for s in summaries}
    return float(by[conc]["throughput_per_sec"])


def _xs(summaries: list[dict], max_c: int) -> list[int]:
    present = {s["concurrency"] for s in summaries}
    return [c for c in LEVELS if c <= max_c and c in present]


def _style_ax(ax: plt.Axes, ylabel: str, title: str, footnote: str) -> None:
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    ax.figure.text(0.5, 0.01, footnote, ha="center", fontsize=8, style="italic")
    ax.figure.tight_layout()
    ax.figure.subplots_adjust(bottom=0.18)


def plot_idle_duration() -> None:
    labels = [
        ("agent", "Repository CPU"),
        ("analytics", "Analytics"),
        ("disk", "Local disk"),
        ("rl", "Numeric loop"),
    ]
    vera = []
    zen = []
    names = []
    for bench, name in labels:
        pins = PINS[bench]
        v_runs, _v_sum = _load_pin(pins["Vera"])
        z_runs, _z_sum = _load_pin(pins["Zen 5"])
        vera.append(_mean_duration_s(v_runs, 1))
        zen.append(_mean_duration_s(z_runs, 1))
        names.append(name)

    x = np.arange(len(names))
    width = 0.36
    fig, ax = plt.subplots(figsize=(9.5, 4.4))
    b1 = ax.bar(x - width / 2, vera, width, label="Vera", color=COLORS["Vera"])
    b2 = ax.bar(x + width / 2, zen, width, label="Zen 5", color=COLORS["Zen 5"])
    ax.bar_label(b1, fmt="%.2f s", padding=2, fontsize=8)
    ax.bar_label(b2, fmt="%.2f s", padding=2, fontsize=8)
    ax.set_xticks(x, names)
    ax.set_xlabel("")
    _style_ax(
        ax,
        "Seconds per job (one sandbox)",
        "Time to finish one job on one vCPU",
        DURATION_NOTE,
    )
    fig.savefig(OUT / "01_idle_duration.png", dpi=150)
    plt.close(fig)


def plot_duration_vs_conc(bench: str, filename: str, title: str, max_c: int = 176) -> None:
    pins = PINS[bench]
    fig, ax = plt.subplots(figsize=(9.5, 4.4))
    for series, rel in pins.items():
        runs, summaries = _load_pin(rel)
        xs = _xs(summaries, max_c)
        ys = [_mean_duration_s(runs, c) for c in xs]
        ax.plot(xs, ys, marker="o", linewidth=2, color=COLORS[series], label=series)
        for x, y in zip(xs, ys):
            ax.annotate(f"{y:.2f}", (x, y), textcoords="offset points", xytext=(0, 7), ha="center", fontsize=7)
    ax.set_xlabel("Concurrent sandboxes")
    ax.set_xticks([c for c in LEVELS if c <= max_c])
    _style_ax(ax, "Seconds per job", title, DURATION_NOTE + " Lower and flatter is better.")
    fig.savefig(OUT / filename, dpi=150)
    plt.close(fig)


def plot_tput_vs_conc(bench: str, filename: str, title: str, max_c: int = 176) -> None:
    pins = PINS[bench]
    fig, ax = plt.subplots(figsize=(9.5, 4.4))
    for series, rel in pins.items():
        _runs, summaries = _load_pin(rel)
        xs = _xs(summaries, max_c)
        ys = [_tput(summaries, c) for c in xs]
        ax.plot(xs, ys, marker="o", linewidth=2, color=COLORS[series], label=series)
        for x, y in zip(xs, ys):
            ax.annotate(f"{y:.1f}", (x, y), textcoords="offset points", xytext=(0, 7), ha="center", fontsize=7)
    ax.set_xlabel("Concurrent sandboxes")
    ax.set_xticks([c for c in LEVELS if c <= max_c])
    _style_ax(ax, "Jobs per second (wave wall)", title, TPUT_NOTE)
    fig.savefig(OUT / filename, dpi=150)
    plt.close(fig)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    plot_idle_duration()
    plot_duration_vs_conc("agent", "02_software_duration.png", "Repository CPU work, time per job")
    plot_duration_vs_conc("disk", "03_disk_duration.png", "Local disk, time per job")
    plot_tput_vs_conc("disk", "04_disk_throughput.png", "Local disk, jobs per second")
    plot_duration_vs_conc("analytics", "05_analytics_duration.png", "Analytics, time per job")
    plot_tput_vs_conc("analytics", "06_analytics_throughput.png", "Analytics, jobs per second")
    plot_duration_vs_conc("rl", "07_numeric_duration.png", "Sequential numeric loop, time per job")
    plot_tput_vs_conc("rl", "08_numeric_throughput.png", "Sequential numeric loop, jobs per second")
    print(f"Wrote charts to {OUT}/")
    for path in sorted(OUT.glob("*.png")):
        print(f"  - {path.name}")


if __name__ == "__main__":
    main()
