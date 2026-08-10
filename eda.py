"""Explore concurrency JSONL results across runners (docker / daytona / rlp / e2b).

Picks the newest ``data/<benchmark>/<runner>/concurrency_*.jsonl`` per runner,
prints a metrics table, and writes comparison charts to
``eda_output/<benchmark>/``.

Benchmark folders under ``data/`` are discovered dynamically (e.g. ``agent``,
``analytics``, ``rl``).

Note: Cloud-sandbox latency includes create + exec + delete; Docker is local
``docker run`` wall time.
"""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"
OUT_DIR = ROOT / "eda_output"
RUNNERS = ("docker", "daytona", "rlp", "e2b")
RUNNER_COLORS = {
    "docker": "#4C78A8",  # blue
    "daytona": "#2CA02C",  # green
    "rlp": "#FF7F0E",  # orange
    "e2b": "#9467BD",  # purple
}

LATENCY_NOTE = (
    "Cloud latency = create + exec + delete; Docker = local docker run wall time"
)


def runner_color(runner: str) -> str:
    return RUNNER_COLORS.get(runner, "#7F7F7F")


def list_benchmark_dirs() -> list[str]:
    """Return data/<name>/ directories (agent, analytics, rl, …)."""
    if not DATA_DIR.is_dir():
        return []
    return sorted(p.name for p in DATA_DIR.iterdir() if p.is_dir() and not p.name.startswith("."))


def latest_jsonl(benchmark: str, runner: str) -> Path | None:
    """Newest concurrency_*.jsonl under data/<benchmark>/<runner>/[target/]."""
    base = DATA_DIR / benchmark / runner
    if not base.is_dir():
        return None
    paths = list(base.glob("concurrency_*.jsonl"))
    # Target subdirs, e.g. data/agent/rlp/arm64-test-1/
    paths.extend(base.glob("*/concurrency_*.jsonl"))
    if not paths:
        return None
    return sorted(paths)[-1]


def discover_datasets(benchmark: str) -> dict[str, Path]:
    found: dict[str, Path] = {}
    for runner in RUNNERS:
        path = latest_jsonl(benchmark, runner)
        if path is not None:
            found[runner] = path
    if not found:
        raise FileNotFoundError(
            f"No concurrency_*.jsonl files under "
            f"{DATA_DIR}/{benchmark}/{{{','.join(RUNNERS)}}}"
        )
    return found


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


def mean_latency(runs: list[dict], concurrency: int) -> float:
    values = [
        float(r["latency_ms"])
        for r in runs
        if r.get("concurrency") == concurrency and "latency_ms" in r
    ]
    return float(np.mean(values)) if values else 0.0


def all_levels(loaded: dict[str, tuple[list[dict], list[dict]]]) -> list[int]:
    return sorted(
        {s["concurrency"] for _, summaries in loaded.values() for s in summaries}
    )


def print_summary_table(
    loaded: dict[str, tuple[list[dict], list[dict]]],
    sources: dict[str, Path],
) -> None:
    print(LATENCY_NOTE)
    print()
    for runner, path in sources.items():
        print(f"{runner}: {path.relative_to(ROOT)}")
    print()

    header = (
        f"{'runner':<10} {'conc':>5} {'p50_ms':>10} {'mean_ms':>10} "
        f"{'p95_ms':>10} {'p99_ms':>10} {'max_ms':>10} {'tput/s':>8} "
        f"{'fail':>5} {'checksum':>8}"
    )
    print(header)
    print("-" * len(header))

    for runner, (runs, summaries) in loaded.items():
        for s in summaries:
            level = s["concurrency"]
            mean_ms = mean_latency(runs, level)
            print(
                f"{runner:<10} {level:5d} "
                f"{s['p50_ms']:10.1f} {mean_ms:10.1f} "
                f"{s['p95_ms']:10.1f} {s['p99_ms']:10.1f} "
                f"{s['max_ms']:10.1f} {s['throughput_per_sec']:8.2f} "
                f"{s['failures']:5d} {str(s.get('checksum_ok')):>8}"
            )
        print()


def plot_grouped_metric(
    loaded: dict[str, tuple[list[dict], list[dict]]],
    out: Path,
    *,
    metric_key: str | None,
    title: str,
    ylabel: str,
    filename: str,
    from_runs_mean: bool = False,
) -> None:
    runners = list(loaded.keys())
    levels = all_levels(loaded)
    x = np.arange(len(levels))
    width = min(0.8 / max(len(runners), 1), 0.25)

    fig, ax = plt.subplots(figsize=(11, 5))
    for i, runner in enumerate(runners):
        runs, summaries = loaded[runner]
        if from_runs_mean:
            values = [mean_latency(runs, level) for level in levels]
        else:
            by_level = {s["concurrency"]: s[metric_key] for s in summaries}
            values = [by_level.get(level, 0) for level in levels]
        offset = (i - (len(runners) - 1) / 2) * width
        bars = ax.bar(
            x + offset, values, width, label=runner, color=runner_color(runner)
        )
        ax.bar_label(bars, fmt="%.0f", padding=2, fontsize=7)

    ax.set_xticks(x, [str(level) for level in levels])
    ax.set_xlabel("Concurrency level")
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    fig.text(0.5, 0.01, LATENCY_NOTE, ha="center", fontsize=8, style="italic")
    fig.tight_layout()
    fig.subplots_adjust(bottom=0.18)
    fig.savefig(out / filename, dpi=150)
    plt.close(fig)


def plot_throughput(
    loaded: dict[str, tuple[list[dict], list[dict]]], out: Path
) -> None:
    fig, ax = plt.subplots(figsize=(9, 5))
    for runner, (_, summaries) in loaded.items():
        levels = [s["concurrency"] for s in summaries]
        tput = [s["throughput_per_sec"] for s in summaries]
        ax.plot(
            levels,
            tput,
            marker="o",
            linewidth=2,
            label=runner,
            color=runner_color(runner),
        )
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
    ax.set_xticks(all_levels(loaded))
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.text(0.5, 0.01, LATENCY_NOTE, ha="center", fontsize=8, style="italic")
    fig.tight_layout()
    fig.subplots_adjust(bottom=0.18)
    fig.savefig(out / "throughput_vs_concurrency.png", dpi=150)
    plt.close(fig)


def plot_latency_boxplots(
    loaded: dict[str, tuple[list[dict], list[dict]]], out: Path
) -> None:
    levels = all_levels(loaded)
    runners = list(loaded.keys())
    fig, axes = plt.subplots(1, len(runners), figsize=(4.5 * len(runners), 5), sharey=True)
    if len(runners) == 1:
        axes = [axes]

    for ax, runner in zip(axes, runners):
        runs, _ = loaded[runner]
        by_level: dict[int, list[float]] = defaultdict(list)
        for run in runs:
            by_level[run["concurrency"]].append(float(run["latency_ms"]))

        data = [by_level.get(level, []) for level in levels]
        color = runner_color(runner)
        bp = ax.boxplot(
            data,
            tick_labels=[str(level) for level in levels],
            showfliers=True,
            patch_artist=True,
        )
        for box in bp["boxes"]:
            box.set_facecolor(color)
            box.set_alpha(0.55)
        for key in ("medians", "whiskers", "caps", "fliers"):
            for artist in bp[key]:
                artist.set_color(color)
        ax.set_title(runner)
        ax.set_xlabel("Concurrency level")
        ax.grid(axis="y", alpha=0.3)

    axes[0].set_ylabel("Latency (ms)")
    fig.suptitle("Raw run latency distribution by concurrency")
    fig.text(0.5, 0.01, LATENCY_NOTE, ha="center", fontsize=8, style="italic")
    fig.tight_layout()
    fig.subplots_adjust(bottom=0.18)
    fig.savefig(out / "latency_boxplots.png", dpi=150)
    plt.close(fig)


def main() -> None:
    available = list_benchmark_dirs()
    parser = argparse.ArgumentParser(description="Vera concurrency EDA")
    parser.add_argument(
        "--benchmark",
        default="agent",
        choices=available or None,
        help=(
            "Which data/<benchmark>/ folder to chart "
            f"(found: {', '.join(available) or 'none'})"
        ),
    )
    args = parser.parse_args()

    if args.benchmark not in available:
        raise SystemExit(
            f"Unknown benchmark folder {args.benchmark!r}. "
            f"Expected a directory under {DATA_DIR}/ "
            f"(found: {', '.join(available) or 'none'})"
        )

    try:
        sources = discover_datasets(args.benchmark)
    except FileNotFoundError as exc:
        raise SystemExit(str(exc)) from exc

    loaded = {runner: load_jsonl(path) for runner, path in sources.items()}
    out = OUT_DIR / args.benchmark
    out.mkdir(parents=True, exist_ok=True)

    print(f"benchmark={args.benchmark}")
    print_summary_table(loaded, sources)

    plot_grouped_metric(
        loaded,
        out,
        metric_key="p50_ms",
        title=f"{args.benchmark}: p50 latency by concurrency",
        ylabel="p50 latency (ms)",
        filename="p50_latency_bars.png",
    )
    plot_grouped_metric(
        loaded,
        out,
        metric_key="p95_ms",
        title=f"{args.benchmark}: p95 latency by concurrency",
        ylabel="p95 latency (ms)",
        filename="p95_latency_bars.png",
    )
    plot_grouped_metric(
        loaded,
        out,
        metric_key=None,
        title=f"{args.benchmark}: mean latency by concurrency",
        ylabel="mean latency (ms)",
        filename="mean_latency_bars.png",
        from_runs_mean=True,
    )
    plot_throughput(loaded, out)
    plot_latency_boxplots(loaded, out)

    print(f"Wrote charts to {out}/")
    for path in sorted(out.glob("*.png")):
        print(f"  - {path.name}")


if __name__ == "__main__":
    main()
