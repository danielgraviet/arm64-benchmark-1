"""RLP sandbox create via SDK ``CreateSandboxFromImageParams``.

Sends ``cpu_arch`` / ``cpu_type`` / ``mode`` from the target profile so ARM64
and Vera cells get the right placement (see ``harness.regions``).
"""

from __future__ import annotations

from typing import Any

from rlp import CreateSandboxFromImageParams, Daytona, Resources
from rlp.sandbox import Sandbox

from harness.regions import (
    require_sdk_field,
    resolve_rlp_cpu_arch,
    resolve_rlp_cpu_type,
    resolve_rlp_mode,
)


def create_rlp_sandbox(
    client: Daytona,
    *,
    image: str,
    timeout: int = 60,
    resources: Resources | None = None,
    cpu_arch: str | None = None,
    cpu_type: str | None = None,
    mode: str | None = None,
    name: str | None = None,
    target: str | None = None,
) -> Sandbox:
    """Create a sandbox and wait until started.

    Defaults from ``target`` when omitted:
    - ``arm64-test-1`` / ``vera`` → ``cpu_arch=arm64``
    - ``vera`` → ``cpu_type=vera``, ``mode=dedicated``
    """
    if cpu_arch is None:
        cpu_arch = resolve_rlp_cpu_arch(target)
    if cpu_type is None:
        cpu_type = resolve_rlp_cpu_type(target)
    if mode is None:
        mode = resolve_rlp_mode(target)

    if cpu_arch is not None:
        require_sdk_field(
            CreateSandboxFromImageParams,
            "cpu_arch",
            purpose=f"cpu_arch={cpu_arch!r}",
        )
    if cpu_type is not None:
        require_sdk_field(
            CreateSandboxFromImageParams,
            "cpu_type",
            purpose=f"cpu_type={cpu_type!r}",
        )

    params = _create_params(
        image=image,
        name=name,
        resources=resources,
        cpu_arch=cpu_arch,
        cpu_type=cpu_type,
        mode=mode,
    )
    region = getattr(client, "_target", None)
    print(
        f"rlp create: region={region!r} cpu_arch={cpu_arch!r} "
        f"cpu_type={cpu_type!r} mode={mode!r} image={image!r} "
        f"cpu={getattr(resources, 'cpu', None)!r}"
    )
    return client.create(params, timeout=timeout)


def _create_params(**kwargs: Any) -> CreateSandboxFromImageParams:
    """Pass only kwargs the installed SDK dataclass accepts (skip None)."""
    fields = CreateSandboxFromImageParams.__dataclass_fields__
    return CreateSandboxFromImageParams(
        **{k: v for k, v in kwargs.items() if k in fields and v is not None}
    )
