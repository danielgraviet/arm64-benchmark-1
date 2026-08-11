"""RLP sandbox create with optional ``cpu_arch`` (resource-type selector).

``rlp-sdk==0.3.2`` forwards ``DaytonaConfig.target`` as ``region`` but does not
yet accept ``cpu_arch`` on ``CreateSandboxFromImageParams``. Eng routes ARM64
capacity with:

    CreateSandboxFromImageParams(image=..., cpu_arch="arm64")

which becomes ``POST /vms`` field ``cpu_arch`` → queue
``jobs.vm.create.<region>.arm64``. Without it, ARM64-region creates fail with
``no matching capacity``.

This helper builds the native create body (same fields we already use) and
injects ``cpu_arch`` when set. Thread-safe for concurrent workers.
"""

from __future__ import annotations

from typing import Any

from rlp import Daytona, Resources
from rlp.sandbox import CODE_TOOLBOX_LANGUAGE_LABEL, Sandbox

from harness.regions import resolve_rlp_cpu_arch


def create_rlp_sandbox(
    client: Daytona,
    *,
    image: str,
    timeout: int = 60,
    resources: Resources | None = None,
    cpu_arch: str | None = None,
    name: str | None = None,
    target: str | None = None,
) -> Sandbox:
    """Create a sandbox and wait until started.

    ``cpu_arch`` defaults from ``target`` via :func:`resolve_rlp_cpu_arch`
    when omitted (``arm64-test-1`` → ``\"arm64\"``).
    """
    if cpu_arch is None:
        cpu_arch = resolve_rlp_cpu_arch(target)

    body: dict[str, Any] = {"image": image}
    region = getattr(client, "_target", None)
    if region and str(region).strip().lower() != "local":
        body["region"] = region
    if cpu_arch:
        body["cpu_arch"] = cpu_arch
    if name:
        body["name"] = name
    if resources is not None:
        if resources.cpu is not None:
            body["cpu"] = resources.cpu
        if resources.memory is not None:
            body["mem_mib"] = int(resources.memory) * 1024
        if resources.disk is not None:
            body["scratch_mib"] = int(resources.disk) * 1024
        if resources.gpu:
            body["gpu_host"] = resources.gpu

    print(
        f"rlp create: region={body.get('region')!r} "
        f"cpu_arch={body.get('cpu_arch')!r} image={image!r}"
    )
    created = client._api.post("/vms", json=body, timeout=timeout or None).json()
    vm = client._api.get(f"/vms/{created['vm_id']}").json()
    sandbox = Sandbox(
        vm,
        client._api,
        client._resolve_toolbox_url(vm),
        client._api_key,
        client._target,
        None,  # language label unused for our workers
        created.get("access_token"),
    )
    # Keep Sandbox constructor aligned with rlp-sdk; language label unused here.
    _ = CODE_TOOLBOX_LANGUAGE_LABEL
    if sandbox.state != "started":
        sandbox.wait_until_started(timeout)
    return sandbox
