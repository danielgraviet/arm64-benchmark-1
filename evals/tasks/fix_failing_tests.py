"""TB-style: broken multi-file package → multi-step oracle fix → heavy verify.

Mirrors Terminal-Bench: unique workspace, fail tests, patch, re-verify.
Sized so a single trial is multi-second of in-sandbox CPU (not create-tax only).
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import Any

# Parametrized cases keep verify honest and CPU-visible.
N_CASES = 320


def setup(workspace: Path, seed: int) -> None:
    pkg = workspace / "app"
    pkg.mkdir(parents=True)
    (pkg / "__init__.py").write_text('"""Broken customer package."""\n', encoding="utf-8")

    # Several modules with intentional bugs (agent-style multi-file fix).
    (pkg / "mathy.py").write_text(
        "def add(a: int, b: int) -> int:\n"
        "    return a - b  # bug: should add\n"
        "\n"
        "def clamp(x: int, lo: int, hi: int) -> int:\n"
        "    return x  # bug: ignore bounds\n",
        encoding="utf-8",
    )
    (pkg / "stats.py").write_text(
        "def mean(xs: list[float]) -> float:\n"
        "    return sum(xs)  # bug: missing / len\n"
        "\n"
        "def moving_sum(xs: list[int], window: int) -> list[int]:\n"
        "    return xs  # bug: stub\n",
        encoding="utf-8",
    )
    (pkg / "texty.py").write_text(
        "def normalize(s: str) -> str:\n"
        "    return s  # bug: should strip + lower\n"
        "\n"
        "def token_count(s: str) -> int:\n"
        "    return len(s)  # bug: should split on whitespace\n",
        encoding="utf-8",
    )

    tests = workspace / "tests"
    tests.mkdir(parents=True)
    (tests / "conftest.py").write_text("", encoding="utf-8")

    cases = "\n".join(
        f"    ({i}, {i + 1}, {2 * i + 1})," for i in range(N_CASES)
    )
    (tests / "test_mathy.py").write_text(
        "import pytest\n"
        "from app.mathy import add, clamp\n"
        "\n"
        f"@pytest.mark.parametrize('a,b,expected', [\n{cases}\n])\n"
        "def test_add(a, b, expected):\n"
        "    assert add(a, b) == expected\n"
        "\n"
        "def test_clamp():\n"
        "    assert clamp(5, 0, 10) == 5\n"
        "    assert clamp(-1, 0, 10) == 0\n"
        "    assert clamp(99, 0, 10) == 10\n",
        encoding="utf-8",
    )
    (tests / "test_stats.py").write_text(
        "from app.stats import mean, moving_sum\n"
        "\n"
        "def test_mean():\n"
        "    assert mean([2.0, 4.0, 6.0]) == 4.0\n"
        "\n"
        "def test_moving_sum():\n"
        "    assert moving_sum([1, 2, 3, 4], 2) == [3, 5, 7]\n",
        encoding="utf-8",
    )
    (tests / "test_texty.py").write_text(
        "from app.texty import normalize, token_count\n"
        "\n"
        "def test_normalize():\n"
        "    assert normalize('  Hi THERE ') == 'hi there'\n"
        "\n"
        "def test_token_count():\n"
        "    assert token_count('a b  c') == 3\n",
        encoding="utf-8",
    )
    # Seed only affects a marker file (checksum-stable layout otherwise).
    (workspace / "SEED.txt").write_text(str(seed), encoding="utf-8")


def _pytest(workspace: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-m", "pytest", "-q", str(workspace / "tests")],
        cwd=workspace,
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, "PYTHONPATH": str(workspace)},
    )


def oracle(workspace: Path, seed: int) -> dict[str, Any]:
    """Multi-step terminal-ish path: observe fail → patch modules → recheck."""
    steps: list[str] = []

    # Step 1: confirm suite fails (agent would run tests first).
    before = _pytest(workspace)
    steps.append(f"pytest_before_exit={before.returncode}")
    if before.returncode == 0:
        return {"steps": steps, "error": "expected failing suite before patch", "seed": seed}

    # Step 2: patch each module (scripted agent edits).
    (workspace / "app" / "mathy.py").write_text(
        "def add(a: int, b: int) -> int:\n"
        "    return a + b\n"
        "\n"
        "def clamp(x: int, lo: int, hi: int) -> int:\n"
        "    return max(lo, min(hi, x))\n",
        encoding="utf-8",
    )
    steps.append("patched app/mathy.py")

    (workspace / "app" / "stats.py").write_text(
        "def mean(xs: list[float]) -> float:\n"
        "    return sum(xs) / len(xs)\n"
        "\n"
        "def moving_sum(xs: list[int], window: int) -> list[int]:\n"
        "    out = []\n"
        "    for i in range(len(xs) - window + 1):\n"
        "        out.append(sum(xs[i : i + window]))\n"
        "    return out\n",
        encoding="utf-8",
    )
    steps.append("patched app/stats.py")

    (workspace / "app" / "texty.py").write_text(
        "def normalize(s: str) -> str:\n"
        "    return ' '.join(s.strip().lower().split())\n"
        "\n"
        "def token_count(s: str) -> int:\n"
        "    return len(s.split())\n",
        encoding="utf-8",
    )
    steps.append("patched app/texty.py")

    # Step 3: intermediate pytest (agent re-runs after edits).
    mid = _pytest(workspace)
    steps.append(f"pytest_after_patch_exit={mid.returncode}")

    return {"steps": steps, "seed": seed, "n_cases": N_CASES}


def verify(workspace: Path) -> dict[str, Any]:
    proc = _pytest(workspace)
    passed = proc.returncode == 0
    # Extra CPU: recompute expected add table (keeps duration meaningful).
    checksum = 0
    for i in range(N_CASES):
        checksum ^= (i + (i + 1)) * (i + 7)
    return {
        "passed": passed,
        "exit_code": proc.returncode,
        "stdout_tail": (proc.stdout or "")[-300:],
        "add_checksum": checksum,
    }
