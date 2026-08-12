"""TB-style: broken launcher scripts + permission fixes + payload CPU check."""

from __future__ import annotations

import hashlib
import os
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any

N_HASH_ITERS = 4_500_000


def setup(workspace: Path, seed: int) -> None:
    bin_dir = workspace / "bin"
    bin_dir.mkdir(parents=True)
    # Payload script uses the same interpreter as the harness (portable).
    script = bin_dir / "hello.py"
    script.write_text(
        "#!/usr/bin/env python3\n"
        "import hashlib\n"
        f"SEED = {seed}\n"
        f"N = {N_HASH_ITERS}\n"
        "print(f'ready-{SEED}')\n"
        "h = hashlib.sha256(str(SEED).encode())\n"
        "for i in range(N):\n"
        "    h.update(str(i).encode())\n"
        "print(f'digest={h.hexdigest()}')\n",
        encoding="utf-8",
    )
    script.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)

    wrapper = bin_dir / "run.sh"
    wrapper.write_text(
        "#!/bin/sh\n"
        "exec ./bin/missing.py\n",
        encoding="utf-8",
    )
    wrapper.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)


def oracle(workspace: Path, seed: int) -> dict[str, Any]:
    _ = seed
    steps: list[str] = []
    hello = workspace / "bin" / "hello.py"
    run = workspace / "bin" / "run.sh"

    hello.chmod(hello.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    steps.append("chmod +x bin/hello.py")

    run.write_text(
        "#!/bin/sh\n"
        "cd \"$(dirname \"$0\")/..\" || exit 1\n"
        f"exec {sys.executable} ./bin/hello.py\n",
        encoding="utf-8",
    )
    run.chmod(run.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    steps.append("rewrote bin/run.sh")

    proc = subprocess.run(
        [str(run)],
        cwd=workspace,
        capture_output=True,
        text=True,
        check=False,
    )
    steps.append(f"smoke_exit={proc.returncode}")
    return {"steps": steps, "smoke_stdout_tail": (proc.stdout or "")[-120:]}


def verify(workspace: Path) -> dict[str, Any]:
    run = workspace / "bin" / "run.sh"
    hello = workspace / "bin" / "hello.py"
    if not run.exists() or not hello.exists():
        return {"passed": False, "reason": "missing scripts"}

    executable = os.access(run, os.X_OK) and os.access(hello, os.X_OK)
    proc = subprocess.run(
        [str(run)],
        cwd=workspace,
        capture_output=True,
        text=True,
        check=False,
    )
    out = (proc.stdout or "").strip().splitlines()
    ready_ok = bool(out) and out[0].startswith("ready-")

    # Independent digest (third hash pass keeps duration meaningful).
    seed_line = out[0] if out else "ready-0"
    seed = int(seed_line.removeprefix("ready-"))
    h = hashlib.sha256(str(seed).encode())
    for i in range(N_HASH_ITERS):
        h.update(str(i).encode())
    want = f"digest={h.hexdigest()}"
    digest_ok = want in out

    passed = executable and proc.returncode == 0 and ready_ok and digest_ok
    return {
        "passed": passed,
        "executable": executable,
        "exit_code": proc.returncode,
        "stdout_head": out[:3],
    }
