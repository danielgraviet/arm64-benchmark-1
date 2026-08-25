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


def build_rlp_resources(
    *,
    cpu: float,
    memory: int | float,
    disk: int | float,
    cpu_max: float | None = None,
    memory_max: int | float | None = None,
) -> Resources:
    """Build ``Resources``, requiring eng SDK fields when burst caps are set."""
    kwargs: dict[str, Any] = {"cpu": cpu, "memory": memory, "disk": disk}
    if cpu_max is not None:
        kwargs["cpu_max"] = cpu_max
    if memory_max is not None:
        kwargs["memory_max"] = memory_max
    fields = getattr(Resources, "__dataclass_fields__", {})
    for name in ("cpu_max", "memory_max"):
        if name in kwargs and name not in fields:
            require_sdk_field(Resources, name, purpose=f"Resources.{name}")
    return Resources(**{k: v for k, v in kwargs.items() if k in fields})


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
    omit_mode: bool = False,
) -> Sandbox:
    """Create a sandbox and wait until started.

    Defaults from ``target`` when omitted:
    - ``arm64-test-1`` / ``vera`` → ``cpu_arch=arm64``
    - ``vera`` → ``cpu_type=vera``, ``mode=dedicated`` (skipped when
      ``omit_mode`` — burstable creates must not reserve a full vCPU)
    """
    if cpu_arch is None:
        cpu_arch = resolve_rlp_cpu_arch(target)
    if cpu_type is None:
        cpu_type = resolve_rlp_cpu_type(target)
    if omit_mode:
        mode = None
    elif mode is None:
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
        f"cpu={getattr(resources, 'cpu', None)!r} "
        f"cpu_max={getattr(resources, 'cpu_max', None)!r} "
        f"memory={getattr(resources, 'memory', None)!r} "
        f"memory_max={getattr(resources, 'memory_max', None)!r} "
        f"disk={getattr(resources, 'disk', None)!r}",
        flush=True,
    )
    sandbox = client.create(params, timeout=timeout)
    print(
        f"rlp create started: id={getattr(sandbox, 'id', None)!r}",
        flush=True,
    )
    return sandbox


def _create_params(**kwargs: Any) -> CreateSandboxFromImageParams:
    """Pass only kwargs the installed SDK dataclass accepts (skip None)."""
    fields = CreateSandboxFromImageParams.__dataclass_fields__
    return CreateSandboxFromImageParams(
        **{k: v for k, v in kwargs.items() if k in fields and v is not None}
    )
