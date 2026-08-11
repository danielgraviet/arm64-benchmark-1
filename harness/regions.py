"""Region / target helpers for RLP (and thin Daytona target passthrough).

RLP region is selected by DaytonaConfig(target=..., toolbox_url=...), not by
image. Known ARM64 values come from tickets/CONTEXT-rlp-arm64-implementation.md.
"""

from __future__ import annotations

from typing import Any

from rlp import DaytonaConfig

# Known-good RLP targets → region-specific toolbox proxy.
# Do not rely on a sticky global RLP_TOOLBOX_URL for these; pass toolbox_url
# explicitly so ARM64 jobs cannot accidentally hit the default x86 proxy.
#
# When the Vera onsite region name is known, add it here (toolbox URL +
# cpu_arch) the same way as arm64-test-1 — unknown --target values fail fast.
RLP_TARGET_TOOLBOX: dict[str, str] = {
    "arm64-test-1": "https://toolbox.arm64-test-1.rlp.trydaytona.com/toolbox",
}

ARM64_TARGETS = frozenset({"arm64-test-1"})
ARM64_MACHINES = frozenset({"aarch64", "arm64"})

# Target → POST /vms cpu_arch (resource-type selector). Required for ARM64
# capacity routing after eng's jobs.vm.create.<region>.arm64 change.
RLP_TARGET_CPU_ARCH: dict[str, str] = {
    "arm64-test-1": "arm64",
}


def resolve_rlp_toolbox_url(target: str | None, toolbox_url: str | None) -> str | None:
    if toolbox_url:
        return toolbox_url
    if target and target in RLP_TARGET_TOOLBOX:
        return RLP_TARGET_TOOLBOX[target]
    return None


def resolve_rlp_cpu_arch(target: str | None) -> str | None:
    """Return ``cpu_arch`` for POST /vms, or None for default-region creates."""
    if not target:
        return None
    return RLP_TARGET_CPU_ARCH.get(target)


def validate_rlp_target(target: str | None) -> None:
    """Fail fast on unknown ``--target`` values (typos → opaque HTTP 400)."""
    if not target:
        return
    if target in RLP_TARGET_TOOLBOX:
        return
    known = ", ".join(sorted(RLP_TARGET_TOOLBOX)) or "(none)"
    hint = ""
    # Common transposition: amr64-test-1 vs arm64-test-1
    if "amr64" in target and "arm64-test-1" in RLP_TARGET_TOOLBOX:
        hint = " Did you mean 'arm64-test-1'?"
    raise ValueError(
        f"Unknown RLP target {target!r}. Known targets: {known}.{hint}"
    )


def resolve_rlp_client_config(
    target: str | None = None,
    toolbox_url: str | None = None,
) -> DaytonaConfig:
    """Build RLP DaytonaConfig for an optional target.

    When ``target`` is None, returns an empty config (SDK falls back to env /
    project default region). When ``target`` is a known ARM64 region, always
    set the matching toolbox URL unless the caller overrides ``toolbox_url``.
    """
    if not target:
        return DaytonaConfig()

    validate_rlp_target(target)
    resolved_toolbox = resolve_rlp_toolbox_url(target, toolbox_url)
    return DaytonaConfig(target=target, toolbox_url=resolved_toolbox)


def check_sandbox_arch(sandbox: Any, target: str | None) -> str:
    """Run platform.machine() on an already-created sandbox.

    For ARM64 targets, fail fast if the machine is not aarch64/arm64.
    Does not create or delete sandboxes — callers should probe on the builder
    or first worker so a capacity-constrained region is not charged twice.
    """
    if not target:
        return "unspecified"

    response = sandbox.process.exec(
        "python -c 'import platform; print(platform.machine())'",
        timeout=30,
    )
    arch = (response.result or "").strip()
    if response.exit_code not in (0, None):
        raise RuntimeError(f"Arch probe failed ({response.exit_code}): {arch}")

    print(f"region probe: target={target!r} arch={arch!r}")
    if target in ARM64_TARGETS and arch not in ARM64_MACHINES:
        raise RuntimeError(
            f"Expected ARM64 on target {target!r}, got {arch!r}. "
            "Check DaytonaConfig(target=..., toolbox_url=...) and "
            "CreateSandbox cpu_arch='arm64' — missing selector often yields "
            "no matching capacity or the wrong arch."
        )
    return arch
