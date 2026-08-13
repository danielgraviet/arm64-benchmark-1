"""Build an E2B template for a Vera benchmark.

    uv run scripts/build_e2b_template.py --benchmark agent
    uv run scripts/build_e2b_template.py --benchmark analytics
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from dotenv import load_dotenv
from e2b import Template, default_build_logger

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from harness.benchmarks import SNAPSHOT_BENCHMARK_IDS, BenchmarkSpec, get_benchmark

sys.path.insert(0, str(Path(__file__).resolve().parent))
from snapshot_common import BASE_IMAGE, ROOT

# E2B default user home; keep in sync with harness/runners/e2b.py.
APP_DIR = "/home/user/app"

IGNORE_PATTERNS = [
    ".git",
    ".venv",
    "**/__pycache__",
    "**/.pytest_cache",
    "**/.mypy_cache",
    "**/.ruff_cache",
    "**/*.egg-info",
    "data",
    "eda_output",
    "tickets",
]


def build_template(base_image: str, spec: BenchmarkSpec):
    venv_python = f"{APP_DIR}/.venv/bin/python"
    builder = (
        Template(
            file_context_path=ROOT,
            file_ignore_patterns=IGNORE_PATTERNS,
        )
        .from_image(base_image)
        .set_user("root")
        .make_dir(APP_DIR)
        .set_workdir(APP_DIR)
    )

    files = [p for p in spec.include_paths if (ROOT / p).is_file()]
    dirs = [p for p in spec.include_paths if (ROOT / p).is_dir()]
    if files:
        builder = builder.copy(files, f"{APP_DIR}/")
    for directory in dirs:
        builder = builder.copy(directory, f"{APP_DIR}/{directory}")

    builder = (
        builder.run_cmd("uv sync --frozen --no-dev")
        .run_cmd(f"chown -R user:user {APP_DIR}")
        .run_cmd(f"{venv_python} -c 'import {spec.module}'")
        .set_envs(spec.run_env(APP_DIR))
        .set_user("user")
    )
    return builder


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build E2B template for a Vera benchmark"
    )
    parser.add_argument(
        "--benchmark",
        default="agent",
        choices=SNAPSHOT_BENCHMARK_IDS,
        help="Which benchmark package to bake into the template",
    )
    parser.add_argument(
        "--name",
        default=None,
        help="Template name (default: per-benchmark artifact name)",
    )
    parser.add_argument(
        "--base-image",
        default=BASE_IMAGE,
        help=f"Base image (default: {BASE_IMAGE})",
    )
    parser.add_argument(
        "--cpu",
        type=int,
        default=1,
        help="CPUs allocated to sandboxes from this template",
    )
    parser.add_argument(
        "--memory-mb",
        type=int,
        default=None,
        help="Memory (MB); default 1024 for agent, 2048 for analytics",
    )
    parser.add_argument(
        "--skip-cache",
        action="store_true",
        help="Force a full rebuild ignoring E2B template cache",
    )
    args = parser.parse_args()
    spec = get_benchmark(args.benchmark)
    name = args.name or spec.artifact_name
    memory_mb = args.memory_mb
    if memory_mb is None:
        memory_mb = 2048 if spec.id == "analytics" else 1024

    load_dotenv(ROOT / ".env")
    template = build_template(args.base_image, spec)
    print(
        f"Building E2B template {name!r} from {args.base_image!r} "
        f"(benchmark={spec.id}) …"
    )
    info = Template.build(
        template,
        name,
        cpu_count=args.cpu,
        memory_mb=memory_mb,
        skip_cache=args.skip_cache,
        on_build_logs=default_build_logger(),
    )
    print(f"Ready on E2B: name={name!r} build={info}")
    print(f"Harness: uv run main.py --benchmark {spec.id} --runner e2b --snapshot {name}")


if __name__ == "__main__":
    main()
