"""Build vera-agent-benchmark as an E2B template.

Matches Docker/Daytona/RLP: same base image + ``uv sync --frozen --no-dev``.

Requires ``E2B_API_KEY`` in `.env`.

    uv run scripts/build_e2b_template.py
    uv run main.py --runner e2b --levels 1 --n 20
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from dotenv import load_dotenv
from e2b import Template, default_build_logger

sys.path.insert(0, str(Path(__file__).resolve().parent))
from snapshot_common import BASE_IMAGE, ROOT, SNAPSHOT_NAME

# E2B default user home; keep in sync with harness/runners/e2b.py.
APP_DIR = "/home/user/app"

# Ignore patterns relative to the template file context (repo root).
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


def build_template(base_image: str):
    venv_python = f"{APP_DIR}/.venv/bin/python"
    return (
        Template(
            file_context_path=ROOT,
            file_ignore_patterns=IGNORE_PATTERNS,
        )
        .from_image(base_image)
        .set_user("root")
        .make_dir(APP_DIR)
        .set_workdir(APP_DIR)
        .copy(["pyproject.toml", "uv.lock"], f"{APP_DIR}/")
        .copy("workload", f"{APP_DIR}/workload")
        .run_cmd("uv sync --frozen --no-dev")
        # Sandboxes run as `user` by default; make the app tree readable/execable.
        .run_cmd(f"chown -R user:user {APP_DIR}")
        # Fail the build if the venv python cannot import the agent deps.
        .run_cmd(
            f"{venv_python} -c 'import pytest; import workload.agent'"
        )
        .set_envs(
            {
                "PATH": f"{APP_DIR}/.venv/bin:/usr/local/bin:/usr/bin:/bin",
                "VIRTUAL_ENV": f"{APP_DIR}/.venv",
                "PYTHONPATH": f"{APP_DIR}/workload/repos/sqlite-utils",
                "PYTHONHASHSEED": "0",
            }
        )
        .set_user("user")
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build vera-agent-benchmark E2B template (aligned with Docker)"
    )
    parser.add_argument("--name", default=SNAPSHOT_NAME, help="Template name")
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
        default=1024,
        help="Memory (MB) allocated to sandboxes from this template",
    )
    parser.add_argument(
        "--skip-cache",
        action="store_true",
        help="Force a full rebuild ignoring E2B template cache",
    )
    args = parser.parse_args()

    load_dotenv(ROOT / ".env")
    template = build_template(args.base_image)
    print(f"Building E2B template {args.name!r} from {args.base_image!r} …")
    info = Template.build(
        template,
        args.name,
        cpu_count=args.cpu,
        memory_mb=args.memory_mb,
        skip_cache=args.skip_cache,
        on_build_logs=default_build_logger(),
    )
    print(f"Ready on E2B: name={args.name!r} build={info}")
    print(f"Harness: uv run main.py --runner e2b --snapshot {args.name}")


if __name__ == "__main__":
    main()
