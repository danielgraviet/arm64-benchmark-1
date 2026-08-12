"""TB-style: missing runner + slow golden checks → oracle wires entrypoint."""

from __future__ import annotations

import hashlib
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

# Dual run (oracle + verify) ≈ multi-second on typical sandbox CPUs.
N_HASH_ITERS = 6_000_000


def setup(workspace: Path, seed: int) -> None:
    pkg = workspace / "tool"
    pkg.mkdir(parents=True)
    (pkg / "__init__.py").write_text("", encoding="utf-8")
    (pkg / "greet.py").write_text(
        "import hashlib\n\n"
        f'NAME = "eval-{seed}"\n\n'
        "def greet() -> str:\n"
        "    return f\"hello {NAME}\"\n\n"
        "def fingerprint(n: int) -> str:\n"
        "    h = hashlib.sha256(NAME.encode())\n"
        "    for i in range(n):\n"
        "        h.update(str(i).encode())\n"
        "    return h.hexdigest()\n",
        encoding="utf-8",
    )
    (workspace / "EXPECTED.txt").write_text(
        f"hello eval-{seed}\n", encoding="utf-8"
    )


def oracle(workspace: Path, seed: int) -> dict[str, Any]:
    runner = workspace / "run_greet.py"
    runner.write_text(
        "from tool.greet import fingerprint, greet\n\n"
        "if __name__ == '__main__':\n"
        "    print(greet())\n"
        f"    print(fingerprint({N_HASH_ITERS}))\n",
        encoding="utf-8",
    )
    env = {**os.environ, "PYTHONPATH": str(workspace)}
    proc = subprocess.run(
        [sys.executable, str(runner)],
        cwd=workspace,
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )
    lines = (proc.stdout or "").strip().splitlines()
    fp = lines[1] if len(lines) > 1 else ""
    (workspace / "FINGERPRINT.txt").write_text(fp + "\n", encoding="utf-8")
    return {
        "runner": "run_greet.py",
        "seed": seed,
        "exit_code": proc.returncode,
        "fingerprint_prefix": fp[:16],
    }


def verify(workspace: Path) -> dict[str, Any]:
    runner = workspace / "run_greet.py"
    expected = (workspace / "EXPECTED.txt").read_text(encoding="utf-8").strip()
    if not runner.exists():
        return {"passed": False, "reason": "missing run_greet.py"}

    env = {**os.environ, "PYTHONPATH": str(workspace)}
    proc = subprocess.run(
        [sys.executable, str(runner)],
        cwd=workspace,
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )
    lines = (proc.stdout or "").strip().splitlines()
    greet_ok = bool(lines) and lines[0] == expected

    seed_name = expected.removeprefix("hello ").strip()
    h = hashlib.sha256(seed_name.encode())
    for i in range(N_HASH_ITERS):
        h.update(str(i).encode())
    want_fp = h.hexdigest()
    got_fp = lines[1] if len(lines) > 1 else ""
    fp_file = (workspace / "FINGERPRINT.txt").read_text(encoding="utf-8").strip()

    passed = (
        proc.returncode == 0
        and greet_ok
        and got_fp == want_fp
        and fp_file == want_fp
    )
    return {
        "passed": passed,
        "stdout_head": lines[:2],
        "exit_code": proc.returncode,
    }
