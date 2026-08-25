"""Determinism and smoke tests for agent coding-agent v3."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _run_agent(n: int, seed: int) -> dict:
    env = os.environ.copy()
    env["PYTHONPATH"] = str(ROOT)
    env["PYTHONHASHSEED"] = "0"
    proc = subprocess.run(
        [
            sys.executable,
            "-m",
            "workload.agent",
            "--task",
            "repo-agent-v3",
            "--n",
            str(n),
            "--seed",
            str(seed),
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )
    assert proc.returncode == 0, proc.stderr or proc.stdout
    line = proc.stdout.strip().splitlines()[-1]
    return json.loads(line)


def test_v3_checksum_deterministic():
    a = _run_agent(24, 42)
    b = _run_agent(24, 42)
    assert a["task"] == "repo-agent-v3"
    assert a["checksum"] == b["checksum"]
    assert a["iterations"] == 24
    assert a["duration_ms"] > 0


def test_v3_seed_changes_checksum():
    a = _run_agent(24, 42)
    b = _run_agent(24, 43)
    assert a["checksum"] != b["checksum"]
