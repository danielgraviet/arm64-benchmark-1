"""On-node RLP target. Localhost only.

Do not point this client at a laptop SSH tunnel. That measures the tunnel.
"""

from __future__ import annotations

import os
from typing import Any

from rlp import DaytonaConfig

LOCAL_TARGET = "local"
DEFAULT_API_URL = "http://127.0.0.1:8088"
DEFAULT_TOOLBOX_URL = "http://127.0.0.1:9000/toolbox"

# Hub image boot (no native NFS snap on this cell).
REGISTRY_BOOT_TARGETS = frozenset({LOCAL_TARGET})


def _env_first(*names: str) -> str:
    for name in names:
        val = (os.environ.get(name) or "").strip()
        if val:
            return val
    return ""


def resolve_rlp_toolbox_url(target: str | None, toolbox_url: str | None) -> str:
    if toolbox_url:
        return toolbox_url
    return _env_first("RLP_TOOLBOX_URL") or DEFAULT_TOOLBOX_URL


def resolve_rlp_cpu_arch(target: str | None) -> str | None:
    return None


def resolve_rlp_cpu_type(target: str | None) -> str | None:
    return None


def resolve_rlp_mode(target: str | None) -> str | None:
    return None


def validate_rlp_target(target: str | None) -> None:
    if not target or target == LOCAL_TARGET:
        return
    raise ValueError(
        f"Unknown RLP target {target!r}. This pack only supports --target local "
        f"(localhost API + toolbox)."
    )


def resolve_rlp_client_config(
    target: str | None = None,
    toolbox_url: str | None = None,
) -> DaytonaConfig:
    """Pin the client to the on-node cell."""
    if target:
        validate_rlp_target(target)
    api_url = _env_first("RLP_API_URL") or DEFAULT_API_URL
    api_key = _env_first("RLP_API_KEY")
    if not api_key:
        raise ValueError("RLP_API_KEY is required in .env")
    resolved_toolbox = resolve_rlp_toolbox_url(target, toolbox_url)
    return _daytona_config(
        api_url=api_url,
        api_key=api_key,
        toolbox_url=resolved_toolbox,
        target=LOCAL_TARGET,
        region_routing=False,
    )


def _daytona_config(**kwargs: Any) -> DaytonaConfig:
    fields = getattr(DaytonaConfig, "__dataclass_fields__", {})
    return DaytonaConfig(
        **{k: v for k, v in kwargs.items() if k in fields and v is not None}
    )


def require_sdk_field(cls: type, name: str, *, purpose: str) -> None:
    fields = getattr(cls, "__dataclass_fields__", {})
    if name in fields:
        return
    raise RuntimeError(
        f"Installed rlp-sdk lacks {cls.__name__}.{name} (needed for {purpose}). "
        "This pack uses PyPI rlp-sdk. If the cell needs extra fields, install "
        "the matching SDK before the ladder."
    )


def check_sandbox_arch(sandbox: Any, target: str | None) -> str:
    response = sandbox.process.exec(
        "python -c 'import platform; print(platform.machine())'",
        timeout=30,
    )
    arch = (response.result or "").strip()
    if response.exit_code not in (0, None):
        raise RuntimeError(f"Arch probe failed ({response.exit_code}): {arch}")
    print(f"region probe: target={target!r} arch={arch!r}")
    return arch
