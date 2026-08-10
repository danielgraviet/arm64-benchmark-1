"""Local Docker worker backend."""

from __future__ import annotations

import json
import subprocess
import time
from typing import Any

IMAGE = "vera-agent-benchmark"


def run_one(n: int, seed: int) -> dict[str, Any]:
    start = time.monotonic()
    result = subprocess.run(
        [
            "docker",
            "run",
            "--rm",
            "--cpus=1",
            "--memory=1g",
            IMAGE,
            "--n",
            str(n),
            "--seed",
            str(seed),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    record: dict[str, Any] = {
        "latency_ms": (time.monotonic() - start) * 1000,
        "exit_code": result.returncode,
    }
    if result.returncode == 0:
        try:
            payload = json.loads(result.stdout.strip())
            record["checksum"] = payload.get("checksum")
            record["duration_ms"] = payload.get("duration_ms")
        except json.JSONDecodeError:
            record["error"] = "invalid_json_output"
            record["stdout"] = result.stdout
    else:
        record["stderr"] = result.stderr
    return record
