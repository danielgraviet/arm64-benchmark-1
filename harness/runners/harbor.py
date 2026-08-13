"""Harbor Terminal-Bench runner (Phase 2).

Harbor owns dataset download, oracle agent, verify, and concurrency.
Each harness ``--levels`` value becomes **one** ``harbor run`` with
``-n <level>`` (do not ThreadPool-fan-out — that would nest concurrency).

CLI mapping:
  --levels  → Harbor ``-n`` (concurrent trials)
  --n       → Harbor ``-l`` / ``--n-tasks`` (0 = no limit / full pack)
  --target  → forwarded as ``DAYTONA_TARGET`` env (Vera region when known)

Requires Harbor CLI (``uv tool install 'harbor[daytona]'``), pinned at smoke
to harbor 0.19.x with dataset ``terminal-bench/terminal-bench-2``.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from harness.paths import ROOT

# Frozen until re-pin (see tickets/evals-terminal-bench-style.md).
DEFAULT_DATASET = "terminal-bench/terminal-bench-2"
DEFAULT_AGENT = "oracle"
DEFAULT_ENV = "daytona"

_JOB_DIR_RE = re.compile(r"jobs[/\\]([A-Za-z0-9._-]+)")


class HarborRunner:
    """Invoke ``harbor run`` once per concurrency level."""

    def __init__(
        self,
        *,
        dataset: str = DEFAULT_DATASET,
        agent: str = DEFAULT_AGENT,
        env: str = DEFAULT_ENV,
        target: str | None = None,
        harbor_bin: str | None = None,
        jobs_dir: Path | None = None,
    ) -> None:
        self._dataset = dataset
        self._agent = agent
        self._env = env
        self._target = target
        self._harbor_bin = harbor_bin or shutil.which("harbor") or "harbor"
        self._jobs_dir = jobs_dir or (ROOT / "data" / "tbench" / "harbor" / "jobs")

    def build_argv(
        self,
        *,
        concurrency: int,
        task_limit: int,
        job_name: str,
    ) -> list[str]:
        if concurrency < 1:
            raise ValueError("Harbor concurrency (-n) must be >= 1")
        argv = [
            self._harbor_bin,
            "run",
            "-d",
            self._dataset,
            "-a",
            self._agent,
            "--env",
            self._env,
            "-n",
            str(concurrency),
            "-o",
            str(self._jobs_dir),
            "--job-name",
            job_name,
            "-y",
        ]
        if task_limit > 0:
            argv.extend(["-l", str(task_limit)])
        return argv

    def run_job(self, *, concurrency: int, task_limit: int, seed: int) -> dict[str, Any]:
        """Run one Harbor job; return a harness-shaped record."""
        self._jobs_dir.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
        job_name = f"vera-tbench-c{concurrency}-n{task_limit}-{stamp}"
        argv = self.build_argv(
            concurrency=concurrency, task_limit=task_limit, job_name=job_name
        )
        env = os.environ.copy()
        if self._target:
            # Region targeting flag for Daytona/Harbor is not frozen yet;
            # pass through as DAYTONA_TARGET for operators / future Harbor support.
            env["DAYTONA_TARGET"] = self._target
        env["PYTHONHASHSEED"] = env.get("PYTHONHASHSEED", "0")

        print(
            f"harbor: dataset={self._dataset!r} agent={self._agent!r} "
            f"env={self._env!r} concurrency={concurrency} "
            f"task_limit={task_limit if task_limit > 0 else 'all'} "
            f"target={self._target!r} job_name={job_name!r}"
        )
        print(f"harbor argv: {' '.join(argv)}")

        start = time.monotonic()
        result = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            check=False,
            env=env,
            cwd=str(ROOT),
        )
        wall_ms = (time.monotonic() - start) * 1000
        stdout = result.stdout or ""
        stderr = result.stderr or ""
        combined = stdout + "\n" + stderr

        job_dir = self._jobs_dir / job_name
        if not job_dir.is_dir():
            # Fallback: parse path from Harbor stdout/stderr.
            parsed = _extract_job_id(combined)
            if parsed:
                candidate = self._jobs_dir / parsed
                job_dir = candidate if candidate.is_dir() else Path("jobs") / parsed

        stats = _read_job_stats(job_dir)
        pass_rate = stats.get("mean_reward")
        if pass_rate is None:
            pass_rate = _extract_pass_rate(combined)

        record: dict[str, Any] = {
            "latency_ms": wall_ms,
            "duration_ms": wall_ms,  # Harbor wall ≈ infra time-to-finish
            "exit_code": result.returncode,
            "benchmark": "tbench",
            "harbor_concurrency": concurrency,
            "task_limit": task_limit if task_limit > 0 else None,
            "dataset": self._dataset,
            "agent": self._agent,
            "harbor_env": self._env,
            "seed": seed,
            "harbor_job_name": job_name,
            "checksum": (
                f"harbor:{self._dataset}:{self._agent}:{concurrency}:{task_limit}"
            ),
        }
        if job_dir.exists():
            record["harbor_job_dir"] = str(job_dir)
            record["harbor_job_id"] = job_dir.name
        if pass_rate is not None:
            record["pass_rate"] = pass_rate
        if "n_completed_trials" in stats:
            record["n_completed_trials"] = stats["n_completed_trials"]
        if "n_errored_trials" in stats:
            record["n_errored_trials"] = stats["n_errored_trials"]
            # Infra red flag: Harbor reported trial errors (not reward < 1).
            if stats["n_errored_trials"] and result.returncode == 0:
                record["exit_code"] = 1
                record["error"] = "harbor_errored_trials"
        if result.returncode != 0:
            record["stderr_tail"] = stderr[-2000:]
            record["stdout_tail"] = stdout[-2000:]
        return record


def _extract_job_id(text: str) -> str | None:
    matches = _JOB_DIR_RE.findall(text)
    return matches[-1] if matches else None


def _extract_pass_rate(text: str) -> float | None:
    """Best-effort parse of Harbor progress / summary pass rate."""
    m = re.search(
        r"Success:\s*(\d+)\s*/\s*(\d+)\s*\(([0-9.]+)\s*%\)",
        text,
        re.IGNORECASE,
    )
    if m:
        return float(m.group(3)) / 100.0
    m = re.search(r"pass[_\s-]?rate[=:\s]+([0-9.]+)", text, re.IGNORECASE)
    if m:
        val = float(m.group(1))
        return val / 100.0 if val > 1.0 else val
    return None


def _read_job_stats(job_dir: Path) -> dict[str, Any]:
    result_path = job_dir / "result.json"
    if not result_path.is_file():
        return {}
    try:
        payload = json.loads(result_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    stats = payload.get("stats") or {}
    out: dict[str, Any] = {
        "n_completed_trials": stats.get("n_completed_trials"),
        "n_errored_trials": stats.get("n_errored_trials"),
    }
    evals = stats.get("evals") or {}
    for eval_stats in evals.values():
        metrics = eval_stats.get("metrics") or []
        if metrics and isinstance(metrics[0], dict) and "mean" in metrics[0]:
            out["mean_reward"] = float(metrics[0]["mean"])
            break
    return {k: v for k, v in out.items() if v is not None}


def run_harbor_suite(
    *,
    levels: list[int],
    task_limit: int,
    seed: int,
    output: Path,
    runner: HarborRunner,
    meta: dict[str, Any] | None = None,
) -> None:
    """One Harbor job per level (no ThreadPool fan-out)."""
    from harness.common import JsonlWriter, summarize

    with JsonlWriter(output) as writer:
        if meta:
            writer.write({"type": "meta", **meta})
        for level in levels:
            start = time.monotonic()
            record = runner.run_job(
                concurrency=level, task_limit=task_limit, seed=seed
            )
            writer.write({"type": "run", "concurrency": level, **record})
            wall_time_s = time.monotonic() - start
            summary = summarize([record], wall_time_s)
            for key in (
                "pass_rate",
                "harbor_job_id",
                "harbor_job_dir",
                "n_completed_trials",
                "n_errored_trials",
            ):
                if key in record:
                    summary[key] = record[key]
            writer.write({"type": "summary", "concurrency": level, **summary})
            print(json.dumps({"concurrency": level, **summary}))
