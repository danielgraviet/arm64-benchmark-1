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
        "Vera": "data/agent/rlp-vera/concurrency_20260821_030511_n200.jsonl",
        "Zen 5": "data/agent/rlp-phoenix/concurrency_20260821_030926_n200.jsonl",
    },
    "disk": {
        "Vera": "data/disk/rlp-vera/concurrency_20260819_202521_n128.jsonl",
        "Zen 5": "data/disk/rlp-phoenix/concurrency_20260820_204117_n128.jsonl",
    },
    "analytics": {
        "Vera": "data/analytics/rlp-vera/concurrency_20260819_222014_n200.jsonl",
        "Zen 5": "data/analytics/rlp-phoenix/concurrency_20260820_201308_n200.jsonl",
    },
    "rl": {
        "Vera": "data/rl/rlp-vera/concurrency_20260819_190856_n5000.jsonl",
        "Zen 5": "data/rl/rlp-phoenix/concurrency_20260820_195139_n5000.jsonl",
    },
}

COLORS = {"Vera": "#8C1D40", "Zen 5": "#C7A000"}
DURATION_NOTE = "Time per job is in-sandbox duration_ms (chip). Create / API / tunnel are not included."
TPUT_NOTE = (
    "Jobs per second uses the full wave wall, including sandbox create and client "
    "dispatch. August 19–21 ladders were laptop/tunnel + pool 100; flattening after "
    "88 is that client, not a Vera socket wall. Quote duration_ms for silicon."
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
        v_runs, v_sum = _load_pin(pins["Vera"])
        z_runs, z_sum = _load_pin(pins["Zen 5"])
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
        DURATION_NOTE + " Lower is faster.",
    )
    fig.savefig(OUT / "01_idle_duration.png", dpi=150)
    plt.close(fig)


def plot_duration_vs_conc(bench: str, filename: str, title: str, max_c: int = 176) -> None:
    pins = PINS[bench]
    fig, ax = plt.subplots(figsize=(9.5, 4.4))
    for series, rel in pins.items():
        runs, summaries = _load_pin(rel)
        xs = [s["concurrency"] for s in summaries if s["concurrency"] <= max_c]
        ys = [_mean_duration_s(runs, c) for c in xs]
        ax.plot(xs, ys, marker="o", linewidth=2, color=COLORS[series], label=series)
        for x, y in zip(xs, ys):
            ax.annotate(f"{y:.2f}", (x, y), textcoords="offset points", xytext=(0, 7), ha="center", fontsize=7)
    ax.set_xlabel("Concurrent sandboxes")
    ax.set_xticks(sorted({s["concurrency"] for s in _load_pin(pins["Vera"])[1] if s["concurrency"] <= max_c}))
    _style_ax(ax, "Seconds per job", title, DURATION_NOTE + " Lower and flatter is better.")
    fig.savefig(OUT / filename, dpi=150)
    plt.close(fig)


def plot_tput_vs_conc(bench: str, filename: str, title: str, max_c: int = 176) -> None:
    pins = PINS[bench]
    fig, ax = plt.subplots(figsize=(9.5, 4.4))
    for series, rel in pins.items():
        _runs, summaries = _load_pin(rel)
        xs = [s["concurrency"] for s in summaries if s["concurrency"] <= max_c]
        ys = [_tput(summaries, c) for c in xs]
        ax.plot(xs, ys, marker="o", linewidth=2, color=COLORS[series], label=series)
        for x, y in zip(xs, ys):
            ax.annotate(f"{y:.1f}", (x, y), textcoords="offset points", xytext=(0, 7), ha="center", fontsize=7)
    ax.set_xlabel("Concurrent sandboxes")
    ax.set_xticks(sorted({s["concurrency"] for s in _load_pin(pins["Vera"])[1] if s["concurrency"] <= max_c}))
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
    plot_duration_vs_conc("rl", "07_numeric_duration.png", "Sequential numeric loop, time per job", max_c=352)
    plot_tput_vs_conc("rl", "08_numeric_throughput.png", "Sequential numeric loop, jobs per second", max_c=352)
    print(f"Wrote charts to {OUT}/")
    for path in sorted(OUT.glob("*.png")):
        print(f"  - {path.name}")


if __name__ == "__main__":
    main()
