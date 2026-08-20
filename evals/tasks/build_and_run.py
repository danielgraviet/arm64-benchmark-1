"""TB-style: missing Makefile → oracle compiles a small C program → golden stdout."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Any

# Tiny LCG in the binary so stdout is seed-dependent; compile is the CPU muscle.
LCG_ITERS = 10_000


def _expected_acc(seed: int) -> int:
    acc = seed
    for _ in range(LCG_ITERS):
        acc = (acc * 1_103_515_245 + 12_345) & 0x7FFFFFFF
    return acc


def _expected_stdout(seed: int) -> str:
    return f"hello eval-{seed}\n{_expected_acc(seed)}\n"


def setup(workspace: Path, seed: int) -> None:
    (workspace / "main.c").write_text(
        "#include <stdio.h>\n"
        "int main(void) {\n"
        f"    int seed = {seed};\n"
        "    long acc = seed;\n"
        f"    for (int i = 0; i < {LCG_ITERS}; i++) {{\n"
        "        acc = (acc * 1103515245 + 12345) & 0x7fffffff;\n"
        "    }\n"
        '    printf("hello eval-%d\\n", seed);\n'
        '    printf("%ld\\n", acc);\n'
        "    return 0;\n"
        "}\n",
        encoding="utf-8",
    )
    # Broken build: agent must replace this before gcc can succeed.
    (workspace / "Makefile").write_text(
        "all:\n\tfalse\n",
        encoding="utf-8",
    )
    (workspace / "EXPECTED.txt").write_text(_expected_stdout(seed), encoding="utf-8")


def _gcc(workspace: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["gcc", "-O2", "-o", "greet", "main.c"],
        cwd=workspace,
        capture_output=True,
        text=True,
        check=False,
        env=os.environ,
    )


def _run_greet(workspace: Path) -> subprocess.CompletedProcess[str]:
    greet = workspace / "greet"
    return subprocess.run(
        [str(greet)],
        cwd=workspace,
        capture_output=True,
        text=True,
        check=False,
    )


def oracle(workspace: Path, seed: int) -> dict[str, Any]:
    steps: list[str] = []
    (workspace / "Makefile").write_text(
        "CC=gcc\n"
        "CFLAGS=-O2\n"
        "greet: main.c\n"
        "\t$(CC) $(CFLAGS) -o greet main.c\n",
        encoding="utf-8",
    )
    steps.append("wrote Makefile")

    compiled = _gcc(workspace)
    steps.append(f"gcc_exit={compiled.returncode}")
    if compiled.returncode != 0:
        return {
            "steps": steps,
            "seed": seed,
            "error": (compiled.stderr or "")[-300:],
        }

    proc = _run_greet(workspace)
    steps.append(f"run_exit={proc.returncode}")
    (workspace / "GOT.txt").write_text(proc.stdout or "", encoding="utf-8")
    return {
        "steps": steps,
        "seed": seed,
        "stdout_head": (proc.stdout or "").strip().splitlines()[:2],
    }


def verify(workspace: Path) -> dict[str, Any]:
    expected = (workspace / "EXPECTED.txt").read_text(encoding="utf-8")
    makefile = (workspace / "Makefile").read_text(encoding="utf-8")
    if "gcc" not in makefile or "false" in makefile.split():
        return {"passed": False, "reason": "Makefile not repaired"}

    compiled = _gcc(workspace)
    if compiled.returncode != 0:
        return {
            "passed": False,
            "reason": "gcc failed",
            "stderr_tail": (compiled.stderr or "")[-300:],
        }

    proc = _run_greet(workspace)
    got = proc.stdout or ""
    passed = proc.returncode == 0 and got == expected
    return {
        "passed": passed,
        "exit_code": proc.returncode,
        "stdout_head": got.strip().splitlines()[:2],
    }
