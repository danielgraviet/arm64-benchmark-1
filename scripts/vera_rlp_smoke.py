"""Smoke: create → exec → delete a sandbox on the onsite Vera RLP cell.

Requires NVIDIA LAN reachability to 10.96.8.181 and VERA_RLP_* in .env.

The Vera cell is self-contained (own API + toolbox). region_routing=False
pins every call to this cell (no catalog fan-out).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from rlp import (
    CreateSandboxFromImageParams,
    Daytona,
    DaytonaConfig,
    Resources,
)

ROOT = Path(__file__).resolve().parent.parent


def _require(name: str) -> str:
    val = (os.environ.get(name) or "").strip()
    if not val:
        raise SystemExit(f"Missing {name} in environment / .env")
    return val


def main() -> None:
    load_dotenv(ROOT / ".env")

    api_url = _require("VERA_RLP_API_URL")
    api_key = _require("VERA_RLP_API_KEY")
    toolbox_url = _require("VERA_RLP_TOOLBOX_URL")
    target = os.environ.get("VERA_RLP_TARGET", "vera").strip() or "vera"

    daytona = Daytona(
        DaytonaConfig(
            api_url=api_url,
            api_key=api_key,
            toolbox_url=toolbox_url,
            target=target,
            region_routing=False,
        )
    )

    sandbox = None
    try:
        print(
            f"creating sandbox on target={target!r} api_url={api_url!r} …",
            flush=True,
        )
        sandbox = daytona.create(
            CreateSandboxFromImageParams(
                image="python:3.12-slim",
                name="vera-sdk-demo",
                cpu_arch="arm64",
                cpu_type="vera",
                mode="dedicated",
                resources=Resources(cpu=1, memory=1, disk=1),
                env_vars={"GREETING": "hello from Olympus"},
            ),
            timeout=120,
        )
        print("sandbox id :", sandbox.id, flush=True)

        r = sandbox.process.exec(
            "uname -m; getconf PAGESIZE; grep -m1 'CPU implementer' /proc/cpuinfo; "
            "python3 -c \"import os;print(os.environ['GREETING'])\""
        )
        print("exit code  :", r.exit_code, flush=True)
        print(r.result, flush=True)

        if r.exit_code not in (0, None):
            raise SystemExit(f"exec failed with exit_code={r.exit_code}")

        out = (r.result or "").lower()
        if "aarch64" not in out and "arm64" not in out:
            print(
                "warning: expected aarch64/arm64 in uname output",
                file=sys.stderr,
            )
        if "hello from olympus" not in out:
            print("warning: GREETING not found in exec output", file=sys.stderr)

        print("smoke OK", flush=True)
    finally:
        if sandbox is not None:
            daytona.delete(sandbox)
            print("deleted", flush=True)


if __name__ == "__main__":
    main()
