#!/usr/bin/env python3
"""Vera onsite Docker EDA → eda_output/vera-docker/

Uses data/*/docker/concurrency_*.jsonl from the onsite haul (P0–P3).
Charts emphasize duration_ms (chip) and throughput (density).
"""

from __future__ import annotations

import json
import re
from collections import defaultdict
from pathlib import Path
from statistics import median

import matplotlib.pyplot as plt
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"
OUT = ROOT / "eda_output" / "vera-docker"

# Headline chip --n (agent uses 200 after P1)
CHIP_N = {
    "analytics": 200,
    "disk": 512,
    "agent": 200,
    "evals": 3,
    "media": 40,
    "rl": 5000,
}
DENSITY_N = {
    "rl": 64,
    "agent": 20,
    "evals": 1,
    "analytics": 10,
    "disk": 128,
    "media": 10,
}
BENCH_ORDER = ["media", "evals", "analytics", "rl", "disk", "agent"]
BENCH_COLORS = {
    "media": "#1B9E77",
    "evals": "#D95F02",
    "analytics": "#7570B3",
    "rl": "#E7298A",
    "disk": "#66A61E",
    "agent": "#E6AB02",
}


def load_jsonl(path: Path) -> tuple[dict | None, list[dict], list[dict]]:
    meta = None
    runs: list[dict] = []
    summaries: list[dict] = []
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            t = row.get("type")
            if t == "meta":
                meta = row
            elif t == "summary":
                summaries.append(row)
            elif t == "run":
                runs.append(row)
    return meta, runs, summaries


def parse_n(path: Path, meta: dict | None) -> int | None:
    if meta and meta.get("n") is not None:
        return int(meta["n"])
    m = re.search(r"_n(\d+)\.jsonl$", path.name)
    return int(m.group(1)) if m else None


def discover() -> list[dict]:
    rows: list[dict] = []
    for path in sorted(DATA.glob("*/docker/concurrency_*.jsonl")):
        meta, runs, summaries = load_jsonl(path)
        if not summaries and not runs:
            continue
        bench = (meta or {}).get("benchmark") or path.parts[-3]
        n = parse_n(path, meta)
        levels = sorted(
            {
                int(s["concurrency"])
                for s in summaries
                if s.get("concurrency") is not None
            }
        )
        if not levels:
            levels = sorted(
                {
                    int(r["concurrency"])
                    for r in runs
                    if r.get("concurrency") is not None
                }
            )
        env = (meta or {}).get("env") or {}
        rows.append(
            {
                "path": path,
                "bench": bench,
                "n": n,
                "seed": (meta or {}).get("seed"),
                "levels": levels,
                "meta": meta,
                "runs": runs,
                "summaries": summaries,
                "arch": env.get("arch"),
            }
        )
    return rows


def summarize_by_c(row: dict) -> dict[int, dict]:
    out: dict[int, dict] = {}
    for s in row["summaries"]:
        c = int(s["concurrency"])
        out[c] = s
    return out


def chip_rows(all_rows: list[dict]) -> list[dict]:
    """c=1 only files at headline chip n (include agent 100 as legacy note separately)."""
    picked = []
    for r in all_rows:
        if len(r["levels"]) != 1 or r["levels"] != [1]:
            continue
        if r["n"] == CHIP_N.get(r["bench"]):
            picked.append(r)
    return picked


def heavy_ladder_rows(all_rows: list[dict]) -> list[dict]:
    """Prefer full 1..88 heavy-n ladders; one newest per bench."""
    best: dict[str, dict] = {}
    for r in all_rows:
        if r["n"] != CHIP_N.get(r["bench"]):
            continue
        if len(r["levels"]) < 3:
            continue
        prev = best.get(r["bench"])
        if prev is None or r["path"].name > prev["path"].name:
            best[r["bench"]] = r
    return [best[b] for b in BENCH_ORDER if b in best]


def density_ladder_rows(all_rows: list[dict]) -> list[dict]:
    """Prefer ladders that include 88 (or 176); newest per bench at density n."""
    best: dict[str, dict] = {}
    for r in all_rows:
        if r["n"] != DENSITY_N.get(r["bench"]):
            continue
        if len(r["levels"]) < 3:
            continue
        prev = best.get(r["bench"])
        # Prefer higher max concurrency (176 > 88)
        score = (max(r["levels"]), r["path"].name)
        prev_score = (
            (max(prev["levels"]), prev["path"].name) if prev else (-1, "")
        )
        if score > prev_score:
            best[r["bench"]] = r
    return [best[b] for b in BENCH_ORDER if b in best]


def style():
    plt.rcParams.update(
        {
            "figure.facecolor": "white",
            "axes.facecolor": "white",
            "axes.grid": True,
            "grid.alpha": 0.25,
            "font.size": 11,
            "axes.titlesize": 13,
            "axes.labelsize": 11,
        }
    )


def save(fig: plt.Figure, name: str) -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / name
    fig.tight_layout()
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"wrote {path}")
    return path


def plot_chip_duration(chip: list[dict]) -> None:
    """Median duration_ms @ c=1 by pack (headline chip)."""
    by_bench: dict[str, list[float]] = defaultdict(list)
    create_by: dict[str, list[float]] = defaultdict(list)
    for r in chip:
        s = summarize_by_c(r).get(1)
        if not s:
            continue
        dur = s.get("p50_duration_ms")
        lat = s.get("p50_ms")
        if dur is None:
            continue
        by_bench[r["bench"]].append(float(dur))
        if lat is not None:
            create_by[r["bench"]].append(float(lat) - float(dur))

    benches = [b for b in BENCH_ORDER if b in by_bench]
    durs = [median(by_bench[b]) / 1000.0 for b in benches]
    creates = [
        median(create_by[b]) / 1000.0 if create_by[b] else 0.0 for b in benches
    ]
    n_runs = [len(by_bench[b]) for b in benches]

    fig, ax = plt.subplots(figsize=(9, 5))
    x = np.arange(len(benches))
    colors = [BENCH_COLORS[b] for b in benches]
    bars = ax.bar(x, durs, color=colors, edgecolor="#333", linewidth=0.6)
    ax.set_xticks(x)
    ax.set_xticklabels(
        [f"{b}\nn={CHIP_N[b]} ({n}×)" for b, n in zip(benches, n_runs)]
    )
    ax.set_ylabel("median duration_ms (seconds)")
    ax.set_title("Vera Docker — chip: in-container duration @ concurrency 1")
    for bar, d, c in zip(bars, durs, creates):
        ax.text(
            bar.get_x() + bar.get_width() / 2,
            bar.get_height(),
            f"{d:.2f}s\n(+{c:.2f}s create)",
            ha="center",
            va="bottom",
            fontsize=9,
        )
    ax.set_ylim(0, max(durs) * 1.25 if durs else 1)
    save(fig, "01_chip_duration_seconds.png")


def plot_chip_duration_vs_create(chip: list[dict]) -> None:
    by_bench: dict[str, list[tuple[float, float]]] = defaultdict(list)
    for r in chip:
        s = summarize_by_c(r).get(1)
        if not s or s.get("p50_duration_ms") is None or s.get("p50_ms") is None:
            continue
        dur = float(s["p50_duration_ms"])
        lat = float(s["p50_ms"])
        by_bench[r["bench"]].append((dur, max(lat - dur, 0.0)))

    benches = [b for b in BENCH_ORDER if b in by_bench]
    durs = [median([t[0] for t in by_bench[b]]) / 1000 for b in benches]
    creates = [median([t[1] for t in by_bench[b]]) / 1000 for b in benches]

    fig, ax = plt.subplots(figsize=(9, 5))
    x = np.arange(len(benches))
    ax.bar(x, durs, label="duration (chip)", color="#2C7FB8", edgecolor="#333")
    ax.bar(
        x,
        creates,
        bottom=durs,
        label="create tax (wall − duration)",
        color="#BDBDBD",
        edgecolor="#333",
    )
    ax.set_xticks(x)
    ax.set_xticklabels(benches)
    ax.set_ylabel("seconds")
    ax.set_title("Vera Docker — chip wall split: work vs container create")
    ax.legend(frameon=False)
    save(fig, "02_chip_wall_split_duration_vs_create.png")


def _plot_heavy_lines(ax, rows: list[dict]) -> None:
    for r in rows:
        by_c = summarize_by_c(r)
        xs = sorted(by_c)
        ys = [
            by_c[c]["p50_duration_ms"] / 1000.0
            for c in xs
            if by_c[c].get("p50_duration_ms") is not None
        ]
        xs = [c for c in xs if by_c[c].get("p50_duration_ms") is not None]
        ax.plot(
            xs,
            ys,
            marker="o",
            linewidth=2,
            label=f"{r['bench']} n={r['n']}",
            color=BENCH_COLORS.get(r["bench"], "#333"),
        )


def plot_heavy_duration(heavy: list[dict]) -> None:
    # Disk blows the y-scale (~150s @88); split panels so CPU packs stay readable.
    cpu = [r for r in heavy if r["bench"] != "disk"]
    disk = [r for r in heavy if r["bench"] == "disk"]
    fig, axes = plt.subplots(1, 2, figsize=(11, 5), sharex=True)
    _plot_heavy_lines(axes[0], cpu)
    axes[0].set_title("CPU / BW packs (excl. disk)")
    axes[0].set_ylabel("p50 duration (seconds)")
    axes[0].legend(frameon=False, fontsize=8)
    _plot_heavy_lines(axes[1], disk if disk else heavy)
    axes[1].set_title("disk only (FS contention)")
    axes[1].set_ylabel("p50 duration (seconds)")
    axes[1].legend(frameon=False, fontsize=8)
    for ax in axes:
        ax.set_xlabel("concurrency")
    fig.suptitle(
        "Vera Docker — heavy ladder: chip work under concurrency", y=1.02
    )
    save(fig, "03_heavy_duration_vs_concurrency.png")


def plot_heavy_throughput(heavy: list[dict]) -> None:
    fig, ax = plt.subplots(figsize=(9, 5.5))
    for r in heavy:
        by_c = summarize_by_c(r)
        xs = sorted(by_c)
        ys = [
            by_c[c].get("throughput_per_sec")
            for c in xs
            if by_c[c].get("throughput_per_sec") is not None
        ]
        xs = [c for c in xs if by_c[c].get("throughput_per_sec") is not None]
        ax.plot(
            xs,
            ys,
            marker="o",
            linewidth=2,
            label=f"{r['bench']} n={r['n']}",
            color=BENCH_COLORS.get(r["bench"], "#333"),
        )
    ax.set_xlabel("concurrency")
    ax.set_ylabel("throughput (jobs / sec)")
    ax.set_title("Vera Docker — heavy ladder: throughput vs concurrency")
    ax.legend(frameon=False, fontsize=9)
    save(fig, "04_heavy_throughput_vs_concurrency.png")


def plot_density_throughput(density: list[dict]) -> None:
    fig, ax = plt.subplots(figsize=(9, 5.5))
    for r in density:
        by_c = summarize_by_c(r)
        xs = sorted(by_c)
        ys = [
            by_c[c].get("throughput_per_sec")
            for c in xs
            if by_c[c].get("throughput_per_sec") is not None
        ]
        xs = [c for c in xs if by_c[c].get("throughput_per_sec") is not None]
        ax.plot(
            xs,
            ys,
            marker="o",
            linewidth=2,
            label=f"{r['bench']} n={r['n']}",
            color=BENCH_COLORS.get(r["bench"], "#333"),
        )
    ax.set_xlabel("concurrency")
    ax.set_ylabel("throughput (jobs / sec)")
    ax.set_title("Vera Docker — density ladder: packing throughput")
    ax.legend(frameon=False, fontsize=9)
    save(fig, "05_density_throughput_vs_concurrency.png")


def plot_density_p99(density: list[dict]) -> None:
    fig, ax = plt.subplots(figsize=(9, 5.5))
    for r in density:
        by_c = summarize_by_c(r)
        xs = sorted(by_c)
        key = "p99_ms" if any(by_c[c].get("p99_ms") for c in xs) else "p95_ms"
        ys = [
            by_c[c].get(key) / 1000.0
            for c in xs
            if by_c[c].get(key) is not None
        ]
        xs = [c for c in xs if by_c[c].get(key) is not None]
        ax.plot(
            xs,
            ys,
            marker="o",
            linewidth=2,
            label=f"{r['bench']} n={r['n']}",
            color=BENCH_COLORS.get(r["bench"], "#333"),
        )
    ax.set_xlabel("concurrency")
    ax.set_ylabel("wall latency (seconds)")
    ax.set_title("Vera Docker — density ladder: wall p99/p95 latency")
    ax.legend(frameon=False, fontsize=9)
    save(fig, "06_density_wall_latency_vs_concurrency.png")


def write_summary_csv(
    chip: list[dict], heavy: list[dict], density: list[dict]
) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / "summary_chip.csv"
    lines = ["benchmark,n,passes,median_duration_ms,median_create_ms,median_wall_ms"]
    by_bench: dict[str, list[tuple[float, float, float]]] = defaultdict(list)
    for r in chip:
        s = summarize_by_c(r).get(1)
        if not s or s.get("p50_duration_ms") is None:
            continue
        dur = float(s["p50_duration_ms"])
        lat = float(s.get("p50_ms") or dur)
        by_bench[r["bench"]].append((dur, max(lat - dur, 0.0), lat))
    for b in BENCH_ORDER:
        if b not in by_bench:
            continue
        durs, creates, lats = zip(*by_bench[b])
        lines.append(
            f"{b},{CHIP_N[b]},{len(durs)},{median(durs):.1f},{median(creates):.1f},{median(lats):.1f}"
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {path}")

    # ladder peaks
    path2 = OUT / "summary_ladders.csv"
    lines2 = [
        "kind,benchmark,n,max_concurrency,p50_duration_ms_at_c1,p50_duration_ms_at_max,throughput_at_max,source"
    ]
    for kind, rows in (("heavy", heavy), ("density", density)):
        for r in rows:
            by_c = summarize_by_c(r)
            c_max = max(by_c)
            s1 = by_c.get(1, {})
            sm = by_c[c_max]
            lines2.append(
                ",".join(
                    [
                        kind,
                        r["bench"],
                        str(r["n"]),
                        str(c_max),
                        f"{s1.get('p50_duration_ms', '')}",
                        f"{sm.get('p50_duration_ms', '')}",
                        f"{sm.get('throughput_per_sec', '')}",
                        r["path"].name,
                    ]
                )
            )
    path2.write_text("\n".join(lines2) + "\n", encoding="utf-8")
    print(f"wrote {path2}")


def main() -> None:
    style()
    all_rows = discover()
    # Prefer aarch64 if tagged; otherwise keep all docker (onsite sync)
    vera = [r for r in all_rows if r.get("arch") in (None, "aarch64")]
    chip = chip_rows(vera)
    # Prefer agent n=200; if we also have n=100 chip files they are excluded by CHIP_N
    heavy = heavy_ladder_rows(vera)
    density = density_ladder_rows(vera)

    print(f"chip passes: {len(chip)}")
    print(f"heavy ladders: {[r['bench'] for r in heavy]}")
    print(f"density ladders: {[ (r['bench'], max(r['levels'])) for r in density]}")

    plot_chip_duration(chip)
    plot_chip_duration_vs_create(chip)
    plot_heavy_duration(heavy)
    plot_heavy_throughput(heavy)
    plot_density_throughput(density)
    plot_density_p99(density)
    write_summary_csv(chip, heavy, density)
    print(f"\nAll charts in {OUT}")


if __name__ == "__main__":
    main()
