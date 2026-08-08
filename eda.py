"""Explore concurrency JSONL results: Mac ARM64 vs EC2 AMD64."""

from __future__ import annotations

import json
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

ROOT = Path(__file__).resolve().parent
OUT_DIR = ROOT / "eda_output"

DATASETS = {
    "Mac ARM64": ROOT / "mac_arm64_concurrency.jsonl",
    "EC2 AMD64": ROOT / "ec2_amd64_concurrency.jsonl",
}


def load_jsonl(path: Path) -> tuple[list[dict], list[dict]]:
    runs: list[dict] = []
    summaries: list[dict] = []
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if row["type"] == "run":
                runs.append(row)
            elif row["type"] == "summary":
                summaries.append(row)
    summaries.sort(key=lambda r: r["concurrency"])
    return runs, summaries


def print_summary_table(loaded: dict[str, tuple[list[dict], list[dict]]]) -> None:
    print(f"{'platform':<12} {'conc':>5} {'p50_ms':>10} {'p95_ms':>10} "
          f"{'p99_ms':>10} {'max_ms':>10} {'tput/s':>8} {'fail':>5}")
    print("-" * 78)
    for name, (_, summaries) in loaded.items():
        for s in summaries:
            print(
                f"{name:<12} {s['concurrency']:5d} "
                f"{s['p50_ms']:10.1f} {s['p95_ms']:10.1f} "
                f"{s['p99_ms']:10.1f} {s['max_ms']:10.1f} "
                f"{s['throughput_per_sec']:8.2f} {s['failures']:5d}"
            )
        print()


def plot_p50_bars(
    loaded: dict[str, tuple[list[dict], list[dict]]], out: Path
) -> None:
    """Grouped bar chart: p50 latency by concurrency level."""
    platforms = list(loaded.keys())
    levels = sorted(
        {s["concurrency"] for _, summaries in loaded.values() for s in summaries}
    )
    x = np.arange(len(levels))
    width = 0.35

    fig, ax = plt.subplots(figsize=(10, 5))
    for i, name in enumerate(platforms):
        by_level = {s["concurrency"]: s["p50_ms"] for s in loaded[name][1]}
        values = [by_level.get(level, 0) for level in levels]
        offset = (i - (len(platforms) - 1) / 2) * width
        bars = ax.bar(x + offset, values, width, label=name)
        ax.bar_label(bars, fmt="%.0f", padding=2, fontsize=7, rotation=90)

    ax.set_xticks(x, [str(level) for level in levels])
    ax.set_xlabel("Concurrency level")
    ax.set_ylabel("p50 latency (ms)")
    ax.set_title("p50 latency by concurrency")
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(out / "p50_latency_bars.png", dpi=150)
    plt.close(fig)


def plot_throughput(
    loaded: dict[str, tuple[list[dict], list[dict]]], out: Path
) -> None:
    """Line chart: throughput vs concurrency."""
    fig, ax = plt.subplots(figsize=(9, 5))
    for name, (_, summaries) in loaded.items():
        levels = [s["concurrency"] for s in summaries]
        tput = [s["throughput_per_sec"] for s in summaries]
        ax.plot(levels, tput, marker="o", linewidth=2, label=name)
        for level, value in zip(levels, tput):
            ax.annotate(
                f"{value:.2f}",
                (level, value),
                textcoords="offset points",
                xytext=(0, 8),
                ha="center",
                fontsize=8,
            )

    ax.set_xlabel("Concurrency level")
    ax.set_ylabel("Throughput (runs / sec)")
    ax.set_title("Throughput vs concurrency")
    ax.set_xticks(
        sorted({s["concurrency"] for _, summaries in loaded.values() for s in summaries})
    )
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out / "throughput_vs_concurrency.png", dpi=150)
    plt.close(fig)


def plot_tail_latency(
    loaded: dict[str, tuple[list[dict], list[dict]]], out: Path
) -> None:
    """Multi-line chart: p50 / p95 / p99 per platform."""
    fig, axes = plt.subplots(1, 2, figsize=(12, 5), sharey=True)
    metrics = [("p50_ms", "p50"), ("p95_ms", "p95"), ("p99_ms", "p99")]
    styles = {"p50": "-", "p95": "--", "p99": ":"}

    for ax, (name, (_, summaries)) in zip(axes, loaded.items()):
        levels = [s["concurrency"] for s in summaries]
        for key, label in metrics:
            ax.plot(
                levels,
                [s[key] for s in summaries],
                marker="o",
                linestyle=styles[label],
                label=label,
            )
        ax.set_title(name)
        ax.set_xlabel("Concurrency level")
        ax.set_xticks(levels)
        ax.grid(True, alpha=0.3)
        ax.legend()

    axes[0].set_ylabel("Latency (ms)")
    fig.suptitle("Tail latency: p50 / p95 / p99")
    fig.tight_layout()
    fig.savefig(out / "tail_latency.png", dpi=150)
    plt.close(fig)


def plot_latency_boxplots(
    loaded: dict[str, tuple[list[dict], list[dict]]], out: Path
) -> None:
    """Box plots of raw run latencies at each concurrency level."""
    levels = sorted(
        {r["concurrency"] for runs, _ in loaded.values() for r in runs}
    )
    platforms = list(loaded.keys())
    fig, axes = plt.subplots(1, len(platforms), figsize=(13, 5), sharey=True)

    for ax, name in zip(axes, platforms):
        runs, _ = loaded[name]
        by_level: dict[int, list[float]] = defaultdict(list)
        for run in runs:
            by_level[run["concurrency"]].append(run["latency_ms"])

        data = [by_level[level] for level in levels]
        ax.boxplot(data, tick_labels=[str(level) for level in levels], showfliers=True)
        ax.set_title(name)
        ax.set_xlabel("Concurrency level")
        ax.grid(axis="y", alpha=0.3)

    axes[0].set_ylabel("Latency (ms)")
    fig.suptitle("Raw run latency distribution by concurrency")
    fig.tight_layout()
    fig.savefig(out / "latency_boxplots.png", dpi=150)
    plt.close(fig)


def main() -> None:
    for path in DATASETS.values():
        if not path.exists():
            raise FileNotFoundError(f"Missing dataset: {path}")

    loaded = {name: load_jsonl(path) for name, path in DATASETS.items()}
    OUT_DIR.mkdir(exist_ok=True)
    print_summary_table(loaded)

    plot_p50_bars(loaded, OUT_DIR)
    plot_throughput(loaded, OUT_DIR)
    plot_tail_latency(loaded, OUT_DIR)
    plot_latency_boxplots(loaded, OUT_DIR)

    print(f"Wrote charts to {OUT_DIR}/")
    for path in sorted(OUT_DIR.glob("*.png")):
        print(f"  - {path.name}")


if __name__ == "__main__":
    main()
