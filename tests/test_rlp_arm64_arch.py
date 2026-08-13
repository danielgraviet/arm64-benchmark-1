"""E2E: RLP arm64-test-1 sandboxes report an ARM64 machine.

Requires ``RLP_API_KEY`` / ``RLP_API_URL`` in the environment or ``.env``.
Excluded from default ``uv run pytest`` via the ``e2e`` marker.

    uv run pytest -m e2e
"""

from __future__ import annotations

import os

import pytest
from dotenv import load_dotenv

from harness.paths import ROOT
from harness.regions import ARM64_MACHINES, resolve_rlp_client_config
from harness.rlp_create import create_rlp_sandbox

pytestmark = pytest.mark.e2e

TARGET = "arm64-test-1"
IMAGE = "python:3.13-slim"


@pytest.fixture(scope="module")
def rlp_credentials_loaded() -> None:
    load_dotenv(ROOT / ".env")
    if not os.getenv("RLP_API_KEY") or not os.getenv("RLP_API_URL"):
        pytest.skip("RLP_API_KEY / RLP_API_URL not set")


def test_e2e_arm64_test_1_platform_machine(rlp_credentials_loaded: None) -> None:
    from rlp import Daytona

    client = Daytona(resolve_rlp_client_config(TARGET))
    sandbox = None
    try:
        sandbox = create_rlp_sandbox(
            client,
            image=IMAGE,
            timeout=180,
            target=TARGET,
        )
        response = sandbox.process.exec(
            "python -c 'import platform; print(platform.machine())'",
            timeout=30,
        )
        arch = (response.result or "").strip()
        assert response.exit_code in (0, None), arch
        print(f"platform.machine()={arch!r} target={TARGET!r}")
        assert arch in ARM64_MACHINES, f"expected ARM64, got {arch!r}"
    finally:
        if sandbox is not None:
            client.delete(sandbox)
