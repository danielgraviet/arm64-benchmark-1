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
(or container) per unit of work by default (``--episodes-per-sandbox 1``).

## Benchmark 3 (RL rollout)

One sandbox = one full mocked rollout **episode** (``n`` sequential steps
inside the container). With ``--episodes-per-sandbox E`` (Daytona/RLP), the
harness creates once, runs ``E`` execs, then deletes — stripping create/delete
from warm episode wall time while ``duration_ms`` stays the chip metric.
"""

from __future__ import annotations

from dataclasses import dataclass

from harness.regions import REGISTRY_BOOT_TARGETS


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
    # System packages installed via apt during Docker/snapshot builds (e.g. ffmpeg).
    apt_packages: tuple[str, ...] = ()
    # Docker Hub ref used on cells without native NFS snaps (Vera, Phoenix).
    registry_image: str = ""

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

    def memory_gib(self) -> int:
        """Parse ``docker_memory`` (e.g. ``2g``) to GiB for RLP ``Resources``."""
        raw = (self.docker_memory or "1g").strip().lower()
        if raw.endswith("gi"):
            return max(1, int(float(raw[:-2])))
        if raw.endswith("g"):
            return max(1, int(float(raw[:-1])))
        if raw.endswith("mi") or raw.endswith("m"):
            mib = float(raw[:-2] if raw.endswith("mi") else raw[:-1])
            return max(1, int((mib + 1023) // 1024))
        return max(1, int(float(raw)))

    def artifact_for_target(self, target: str | None = None) -> str:
        """Snapshot/template name for an optional region target.

        Default-region builds keep the short artifact name
        (``vera-analytics-benchmark``). Targeted builds (e.g. ARM64) get a
        distinct suffix so rebuilds do not delete/overwrite the default-region
        snapshot of the same benchmark.

        Vera and Phoenix boot the Docker Hub image: those cells do not have
        the west-1 native NFS manifests. See ``boot_image_for_rlp``.
        """
        if not target:
            return self.artifact_name
        safe = target.replace("/", "-")
        return f"{self.artifact_name}-{safe}"

    def boot_image_for_rlp(self, target: str | None = None) -> str:
        """Image/snapshot string passed to RLP create for this target."""
        if target in REGISTRY_BOOT_TARGETS:
            if not self.registry_image:
                raise ValueError(
                    f"Benchmark {self.id!r} has no registry_image for target {target!r}"
                )
            return self.registry_image
        return self.artifact_for_target(target)


AGENT = BenchmarkSpec(
    id="agent",
    task_name="repo-agent-v2",
    docker_image="vera-agent-benchmark",
    artifact_name="vera-agent-benchmark",
    module="workload.agent",
    include_paths=("pyproject.toml", "uv.lock", "workload"),
    pythonpath_extra="workload/repos/sqlite-utils",
    docker_memory="1g",
    description="Repo-agent style CPU work: isolated tmp workspace, search/AST/edit/pytest/SQL",
    registry_image="dtgraviet/vera-agent-benchmark:latest",
)

ANALYTICS = BenchmarkSpec(
    id="analytics",
    task_name="analytics-parquet-v1",
    docker_image="vera-analytics-benchmark",
    artifact_name="vera-analytics-benchmark",
    module="analytics.agent",
    include_paths=("pyproject.toml", "uv.lock", "analytics"),
    pythonpath_extra=None,
    docker_memory="4g",
    description="Memory-bandwidth heavy Parquet + DuckDB joins/filters/aggs",
    registry_image="dtgraviet/vera-agent-benchmark-analytics:latest",
)

RL = BenchmarkSpec(
    id="rl",
    task_name="rl-rollout-v2",
    docker_image="vera-rl-benchmark",
    artifact_name="vera-rl-benchmark",
    module="rl.agent",
    include_paths=("pyproject.toml", "uv.lock", "rl"),
    pythonpath_extra=None,
    docker_memory="1g",
    description="Mocked RL rollout: batched env/policy steps, no network/GPU",
    registry_image="dtgraviet/vera-agent-benchmark-rl:latest",
)

EVALS = BenchmarkSpec(
    id="evals",
    task_name="evals-tb-style-v3",
    docker_image="vera-evals-benchmark",
    artifact_name="vera-evals-benchmark",
    module="evals.agent",
    include_paths=("pyproject.toml", "uv.lock", "evals"),
    pythonpath_extra=None,
    docker_memory="1g",
    description="Terminal-Bench–style evals: log-surgery oracle+verify per sandbox (no LLM)",
    apt_packages=("gcc", "libc6-dev"),
    registry_image="dtgraviet/vera-agent-benchmark-evals:latest",
)

MEDIA = BenchmarkSpec(
    id="media",
    task_name="media-transcode-v1",
    docker_image="vera-media-benchmark",
    artifact_name="vera-media-benchmark",
    module="media.agent",
    include_paths=("pyproject.toml", "uv.lock", "media"),
    pythonpath_extra=None,
    docker_memory="2g",
    description="FFmpeg h.264 transcode of synthetic frames (bandwidth / agent media preprocess)",
    apt_packages=("ffmpeg",),
    registry_image="dtgraviet/vera-agent-benchmark-media:latest",
)

DISK = BenchmarkSpec(
    id="disk",
    task_name="sandbox-disk-v1",
    docker_image="vera-disk-benchmark",
    artifact_name="vera-disk-benchmark",
    module="disk.agent",
    include_paths=("pyproject.toml", "uv.lock", "disk"),
    pythonpath_extra=None,
    docker_memory="2g",
    description="Sandbox disk I/O: sequential write/fsync/read + small-file storm",
    registry_image="dtgraviet/vera-agent-benchmark-disk:latest",
)

# Phase 2: real Harbor Terminal-Bench. No local image/module — runner=harbor only.
TBENCH = BenchmarkSpec(
    id="tbench",
    task_name="harbor-terminal-bench-2-oracle",
    docker_image="",  # unused — Harbor owns task images
    artifact_name="harbor-terminal-bench-2",
    module="",  # unused
    include_paths=(),
    pythonpath_extra=None,
    docker_memory="1g",
    description="Harbor Terminal-Bench 2 oracle pack (infra time-to-finish, not accuracy)",
)

BENCHMARKS: dict[str, BenchmarkSpec] = {
    AGENT.id: AGENT,
    ANALYTICS.id: ANALYTICS,
    RL.id: RL,
    EVALS.id: EVALS,
    MEDIA.id: MEDIA,
    DISK.id: DISK,
    TBENCH.id: TBENCH,
}

BENCHMARK_IDS = tuple(BENCHMARKS)

# Snapshot/template builders only apply to in-repo workload packs.
SNAPSHOT_BENCHMARK_IDS = tuple(b for b in BENCHMARK_IDS if b != TBENCH.id)


def get_benchmark(benchmark_id: str) -> BenchmarkSpec:
    try:
        return BENCHMARKS[benchmark_id]
    except KeyError as exc:
        known = ", ".join(BENCHMARK_IDS)
        raise ValueError(f"Unknown benchmark {benchmark_id!r}. Choose from: {known}") from exc
