"""Multi-benchmark registry and shared container contract.

## Container / JSON contract (all benchmarks)

Each worker (Docker image or sandbox snapshot/template) must:

1. Start offline (deps baked in; no network install at run time).
2. Accept ``--n`` (work volume) and ``--seed`` (determinism).
3. Run a deterministic local workload.
4. Print **one** JSON object to stdout with at least:
   ``task``, ``iterations``, ``duration_ms``, ``checksum``.
5. Exit ``0`` on success; non-zero on failure (stderr may explain).

Checksum is a hash of **workload outputs**, not source files — so every
runner/backend completing the same ``(n, seed)`` should agree.

## Harness API

Today the suite calls a single-shot worker:

    run_one(n: int, seed: int) -> dict  # latency_ms, exit_code, checksum, …

That matches Benchmark 1 (agent) and Benchmark 2 (analytics): one sandbox
(or container) per unit of work.

## Benchmark 3 (RL rollout)

One sandbox = one full mocked rollout **episode** (``n`` sequential steps
inside the container). Harness API stays ``run_one(n, seed)`` — no runner
changes. Phase 2 may reuse a long-lived sandbox across episodes to strip
create/delete cost.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class BenchmarkSpec:
    """Describes one benchmark package for harness + image builders."""

    id: str
    task_name: str
    docker_image: str
    artifact_name: str
    module: str
    include_paths: tuple[str, ...]
    pythonpath_extra: str | None = None
    docker_memory: str = "1g"
    description: str = ""

    def agent_argv(self, n: int, seed: int) -> list[str]:
        return ["--n", str(n), "--seed", str(seed), "--task", self.task_name]

    def run_env(self, app_dir: str) -> dict[str, str]:
        env = {
            "PATH": f"{app_dir}/.venv/bin:/usr/local/bin:/usr/bin:/bin",
            "VIRTUAL_ENV": f"{app_dir}/.venv",
            "PYTHONHASHSEED": "0",
        }
        if self.pythonpath_extra:
            env["PYTHONPATH"] = f"{app_dir}/{self.pythonpath_extra}"
        return env

    def agent_command(self, *, python: str = "python") -> str:
        return f"{python} -m {self.module}"

    def artifact_for_target(self, target: str | None = None) -> str:
        """Snapshot/template name for an optional region target.

        Default-region builds keep the short artifact name
        (``vera-analytics-benchmark``). Targeted builds (e.g. ARM64) get a
        distinct suffix so rebuilds do not delete/overwrite the default-region
        snapshot of the same benchmark.
        """
        if not target:
            return self.artifact_name
        safe = target.replace("/", "-")
        return f"{self.artifact_name}-{safe}"


AGENT = BenchmarkSpec(
    id="agent",
    task_name="repo-agent-v1",
    docker_image="vera-agent-benchmark",
    artifact_name="vera-agent-benchmark",
    module="workload.agent",
    include_paths=("pyproject.toml", "uv.lock", "workload"),
    pythonpath_extra="workload/repos/sqlite-utils",
    docker_memory="1g",
    description="Repo-agent style CPU work: search, AST, edit, pytest, SQL",
)

ANALYTICS = BenchmarkSpec(
    id="analytics",
    task_name="analytics-parquet-v1",
    docker_image="vera-analytics-benchmark",
    artifact_name="vera-analytics-benchmark",
    module="analytics.agent",
    include_paths=("pyproject.toml", "uv.lock", "analytics"),
    pythonpath_extra=None,
    docker_memory="2g",
    description="Memory-bandwidth heavy Parquet + DuckDB joins/filters/aggs",
)

RL = BenchmarkSpec(
    id="rl",
    task_name="rl-rollout-v1",
    docker_image="vera-rl-benchmark",
    artifact_name="vera-rl-benchmark",
    module="rl.agent",
    include_paths=("pyproject.toml", "uv.lock", "rl"),
    pythonpath_extra=None,
    docker_memory="1g",
    description="Mocked RL rollout: sequential env/policy steps, no network/GPU",
)

BENCHMARKS: dict[str, BenchmarkSpec] = {
    AGENT.id: AGENT,
    ANALYTICS.id: ANALYTICS,
    RL.id: RL,
}

BENCHMARK_IDS = tuple(BENCHMARKS)


def get_benchmark(benchmark_id: str) -> BenchmarkSpec:
    try:
        return BENCHMARKS[benchmark_id]
    except KeyError as exc:
        known = ", ".join(BENCHMARK_IDS)
        raise ValueError(f"Unknown benchmark {benchmark_id!r}. Choose from: {known}") from exc
