#!/usr/bin/env python3
"""Vera OCI vs EPYC 9575F create-ready charts. Same recipe, two chips.

    uv run python daniel-focus-here/docs/plot_create_chip_compare.py

Writes create-chip-line.png and create-chip-steps.png next to this file.
"""

from __future__ import annotations

import sys
from pathlib import Path

import matplotlib.pyplot as plt

DOCS = Path(__file__).resolve().parent
if str(DOCS) not in sys.path:
    sys.path.insert(0, str(DOCS))

from oci_create_where_load import RUNS, JSONL_DIR, CreateRun, load_run  # noqa: E402

VERA = "#76B900"
VERA_WAIT = "#C5E38A"
AMD = "#6F7177"
AMD_WAIT = "#C5C6C9"

AMD_RUNS = (
    "epyc9575_create_ready_1000_20261012_180355.jsonl",
    "epyc9575_create_ready_1000_20261012_181145.jsonl",
    "epyc9575_create_ready_1000_20261012_181231.jsonl",
)


def _mean(values: list[float]) -> float:
    return sum(values) / len(values)


def _apply_style() -> None:
    plt.rcParams.update(
        {
            "figure.facecolor": "white",
            "axes.facecolor": "white",
            "axes.grid": False,
            "font.size": 11,
            "axes.titlesize": 13,
            "axes.labelsize": 11,
            "legend.fontsize": 10,
        }
    )


def _amd_runs() -> list[CreateRun]:
    root = JSONL_DIR.parent / "zen5-9575f-jsonl"
    return [load_run(root / name) for name in AMD_RUNS]


def _vera_runs() -> list[CreateRun]:
    return [load_run(JSONL_DIR / name) for name in RUNS]


def _slice(runs: list[CreateRun], kind: str) -> tuple[float, float]:
    if kind == "first":
        return (
            _mean([run.first.post_s for run in runs]),
            _mean([run.first.wait_s for run in runs]),
        )
    if kind == "typical":
        return (
            _mean([run.typical_post_s for run in runs]),
            _mean([run.typical_wait_s for run in runs]),
        )
    return (
        _mean([run.last.post_s for run in runs]),
        _mean([run.last.wait_s for run in runs]),
    )


def plot_line(vera: list[CreateRun], amd: list[CreateRun], out: Path) -> None:
    """One row per place in the batch. Vera is green. The 9575F is grey."""
    kinds = ("Last", "Typical", "First")
    chips = (
        ("Vera", vera, VERA, VERA_WAIT),
        ("9575F", amd, AMD, AMD_WAIT),
    )
    _apply_style()
    fig, ax = plt.subplots(figsize=(7.4, 3.8))
    ax.grid(axis="x", alpha=0.28)
    ys = list(range(len(kinds)))
    height = 0.36
    for chip, runs, accept_color, wait_color in chips:
        shift = 0.2 if chip == "Vera" else -0.2
        accept = []
        pickup = []
        for kind in kinds:
            post_s, wait_s = _slice(runs, kind.lower())
            accept.append(post_s)
            pickup.append(wait_s)
        positions = [y + shift for y in ys]
        ax.barh(
            positions,
            accept,
            color=accept_color,
            height=height,
            label=f"{chip}, control plane",
        )
        ax.barh(
            positions,
            pickup,
            left=accept,
            color=wait_color,
            height=height,
            label=f"{chip}, waiting for a runner",
        )
        for pos, post_s, wait_s in zip(positions, accept, pickup):
            ax.text(post_s + wait_s + 0.4, pos, f"{post_s + wait_s:.1f}s", va="center", fontsize=9)
    ax.set_yticks(ys, list(kinds))
    ax.set_xlabel("Seconds until that sandbox is ready")
    ax.set_xlim(0, 42)
    ax.set_title("The line in front of the start")
    ax.legend(
        loc="upper center",
        bbox_to_anchor=(0.5, -0.16),
        ncol=2,
        frameon=False,
    )
    fig.savefig(out, dpi=160, bbox_inches="tight")
    plt.close(fig)


def plot_steps(vera: list[CreateRun], amd: list[CreateRun], out: Path) -> None:
    def steps(runs: list[CreateRun]) -> list[tuple[str, float]]:
        return [
            ("Scratch disk", _mean([run.scratch_p50_ms for run in runs])),
            ("Load memory", _mean([run.memory_p50_ms for run in runs])),
            ("Start the VM", _mean([run.vm_start_p50_ms for run in runs])),
            ("Guest ready", _mean([run.guest_ready_p50_ms for run in runs])),
            ("Command check", _mean([run.typical_probe_s for run in runs]) * 1000.0),
        ]

    vera_steps = steps(vera)
    amd_steps = steps(amd)
    labels = [name for name, _ms in vera_steps]
    vera_ms = [ms for _name, ms in vera_steps]
    amd_ms = [ms for _name, ms in amd_steps]
    vera_together = _mean([run.boot_p50_ms for run in vera])
    amd_together = _mean([run.boot_p50_ms for run in amd])

    _apply_style()
    fig, ax = plt.subplots(figsize=(7.4, 3.4))
    ax.grid(axis="x", alpha=0.28)
    positions = list(range(len(labels)))
    ax.barh([p + 0.18 for p in positions], vera_ms, color=VERA, height=0.34, label="Vera")
    ax.barh([p - 0.18 for p in positions], amd_ms, color=AMD, height=0.34, label="9575F")
    for pos, ms in zip(positions, vera_ms):
        ax.text(ms + 30, pos + 0.18, f"{ms:.0f} ms", va="center", fontsize=9, color=VERA)
    for pos, ms in zip(positions, amd_ms):
        ax.text(ms + 30, pos - 0.18, f"{ms:.0f} ms", va="center", fontsize=9, color=AMD)
    ax.set_yticks(positions, labels)
    ax.set_xlabel("Milliseconds. These steps overlap inside the start.")
    ax.set_xlim(0, max(amd_ms) * 1.45)
    ax.set_title(
        f"Steps inside one start. Together: Vera {vera_together:.0f} ms, "
        f"9575F {amd_together:.0f} ms"
    )
    ax.legend(
        loc="upper center",
        bbox_to_anchor=(0.5, -0.16),
        ncol=2,
        frameon=False,
    )
    fig.savefig(out, dpi=160, bbox_inches="tight")
    plt.close(fig)


def main() -> None:
    vera = _vera_runs()
    amd = _amd_runs()
    line_path = DOCS / "create-chip-line.png"
    steps_path = DOCS / "create-chip-steps.png"
    plot_line(vera, amd, line_path)
    plot_steps(vera, amd, steps_path)
    print(f"wrote {line_path}")
    print(f"wrote {steps_path}")
    print(
        "vera together",
        _mean([run.boot_p50_ms for run in vera]),
        "amd together",
        _mean([run.boot_p50_ms for run in amd]),
    )


if __name__ == "__main__":
    main()
