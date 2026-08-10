"""Concurrency harness that runs one agent workload per Daytona sandbox.

Mirrors scripts/concurrency.py (1 Docker container = 1 run), but each worker
is an ephemeral Daytona sandbox created from the vera-agent-benchmark snapshot.

Latency includes sandbox create + process.exec + delete.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from collections.abc import Iterator
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any

from daytona import (
    CreateSandboxFromSnapshotParams,
    Daytona,
    DaytonaConfig,
)
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

from concurrency import JsonlWriter, summarize

SNAPSHOT_NAME = "vera-agent-benchmark"
APP_DIR = "/home/daytona/app"
# Workload at n=20 can take minutes under contention; leave headroom.
DEFAULT_EXEC_TIMEOUT_S = 600
RUN_ENV = {
    "PYTHONPATH": f"{APP_DIR}/workload/repos/sqlite-utils",
    "PYTHONHASHSEED": "0",
}


def run_one(
    daytona: Daytona,
    snapshot: str,
    n: int,
    seed: int,
    exec_timeout_s: int,
) -> dict[str, Any]:
    start = time.monotonic()
    sandbox = None
    try:
        sandbox = daytona.create(
            CreateSandboxFromSnapshotParams(
                snapshot=snapshot,
                ephemeral=True,
                language="python",
            ),
            timeout=120,
        )
        response = sandbox.process.exec(
            f"python main.py --n {n} --seed {seed}",
            cwd=APP_DIR,
            env=RUN_ENV,
            timeout=exec_timeout_s,
        )
        exit_code = int(response.exit_code or 0)
        stdout = (response.result or "").strip()

        record: dict[str, Any] = {
            "latency_ms": (time.monotonic() - start) * 1000,
            "exit_code": exit_code,
            "sandbox_id": sandbox.id,
        }
        if exit_code == 0:
            try:
                payload = json.loads(stdout)
                record["checksum"] = payload.get("checksum")
                record["duration_ms"] = payload.get("duration_ms")
            except json.JSONDecodeError:
                record["error"] = "invalid_json_output"
                record["stdout"] = stdout
        else:
            record["stderr"] = stdout
        return record
    except Exception as exc:  # noqa: BLE001 — capture per-worker failures
        return {
            "latency_ms": (time.monotonic() - start) * 1000,
            "exit_code": -1,
            "error": f"{type(exc).__name__}: {exc}",
        }
    finally:
        if sandbox is not None:
            try:
                daytona.delete(sandbox)
            except Exception:  # noqa: BLE001, S110
                pass


def run_level(
    daytona: Daytona,
    concurrency: int,
    n: int,
    seed: int,
    snapshot: str,
    exec_timeout_s: int,
) -> Iterator[dict[str, Any]]:
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [
            pool.submit(run_one, daytona, snapshot, n, seed, exec_timeout_s)
            for _ in range(concurrency)
        ]
        for future in as_completed(futures):
            yield future.result()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Vera concurrency harness on Daytona sandboxes"
    )
    parser.add_argument(
        "--levels", type=int, nargs="+", default=[1, 8, 22, 44, 88, 176]
    )
    parser.add_argument("--n", type=int, default=20)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--output", type=str, default="daytona_concurrency.jsonl")
    parser.add_argument("--snapshot", type=str, default=SNAPSHOT_NAME)
    parser.add_argument(
        "--exec-timeout",
        type=int,
        default=DEFAULT_EXEC_TIMEOUT_S,
        help="Seconds allowed for process.exec of main.py inside each sandbox",
    )
    args = parser.parse_args()

    load_dotenv(ROOT / ".env")
    daytona = Daytona(DaytonaConfig(connection_pool_maxsize=None))

    with JsonlWriter(Path(args.output)) as writer:
        for level in args.levels:
            start = time.monotonic()
            records: list[dict[str, Any]] = []

            for record in run_level(
                daytona,
                level,
                args.n,
                args.seed,
                args.snapshot,
                args.exec_timeout,
            ):
                writer.write({"type": "run", "concurrency": level, **record})
                records.append(record)

            wall_time_s = time.monotonic() - start
            summary = summarize(records, wall_time_s)
            writer.write({"type": "summary", "concurrency": level, **summary})
            print(json.dumps({"concurrency": level, **summary}))


if __name__ == "__main__":
    main()
