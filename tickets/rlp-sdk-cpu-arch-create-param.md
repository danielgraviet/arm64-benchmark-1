# rlp-sdk: forward `cpu_arch` on sandbox create (ARM64 resource selector)

**Status:** Open — ready for SDK PR  
**Product:** `rlp-sdk` (Python) / rl-platform  
**Severity:** High — ARM64 region creates fail without this field  
**Date:** 2026-08-11  
**Reporter:** Daniel Graviet  
**Baseline package:** `rlp-sdk==0.3.2`

---

## Summary

The control plane now routes creates with a **resource-type selector**
`cpu_arch` (e.g. `"arm64"`) so jobs land on
`jobs.vm.create.<region>.arm64`.

`DaytonaConfig(target=..., toolbox_url=...)` alone is not enough. Without
`cpu_arch` on `POST /vms`, ARM64-region creates fail with:

```text
create job not picked up by any runner within 60s (no matching capacity)
```

Eng’s intended client API:

```python
from rlp import CreateSandboxFromImageParams, Daytona, DaytonaConfig

client = Daytona(DaytonaConfig(
    target="arm64-test-1",
    toolbox_url="https://toolbox.arm64-test-1.rlp.trydaytona.com/toolbox",
))

sandbox = client.create(
    CreateSandboxFromImageParams(
        image="python:3.13-slim",
        cpu_arch="arm64",  # routes to jobs.vm.create.arm64-test-1.arm64
    ),
    timeout=120,
)
```

In `rlp-sdk==0.3.2` this raises:

```text
TypeError: CreateSandboxFromImageParams.__init__() got an unexpected keyword argument 'cpu_arch'
```

even if callers set the field somehow, `Daytona.create` never puts `cpu_arch`
on the JSON body.

---

## SDK gap (0.3.2)

| Layer | File (approx.) | Problem |
| --- | --- | --- |
| Params DTO | `rlp/config.py` → `CreateSandboxBaseParams` / `CreateSandboxFromImageParams` | No `cpu_arch` field |
| Create path | `rlp/daytona.py` → `Daytona.create` | Builds `POST /vms` body with `region` from config, but never forwards `cpu_arch` |

`Daytona.create` already maps `config.target` → body `"region"`. The missing
piece is mapping `params.cpu_arch` → body `"cpu_arch"`.

---

## Fix (PR checklist)

### 1. Add the field on create params

In `rlp/config.py`, on `CreateSandboxBaseParams` (so both image and snapshot
creates can select arch):

```python
@dataclass
class CreateSandboxBaseParams:
    # ... existing fields ...
    # Resource-type selector for the scheduler (e.g. "arm64", "amd64").
    # Forwarded as POST /vms "cpu_arch". Required for non-default arch
    # regions such as arm64-test-1 after resource-type selectors landed.
    cpu_arch: Optional[str] = None
```

Docstring should note known values (`"arm64"`, and whatever x86 uses if
explicit — often omitted for default region).

### 2. Forward it in `Daytona.create`

In `rlp/daytona.py`, where the `/vms` body is assembled (next to the
`region` block is ideal):

```python
if self._target and self._target.strip().lower() != "local":
    body["region"] = self._target

if params and getattr(params, "cpu_arch", None):
    body["cpu_arch"] = params.cpu_arch
```

Use the same pattern as other optional scalar fields (`name`, `mode`, …).
Do **not** invent a default `cpu_arch` when unset — omit the key so
default-region behavior stays unchanged.

### 3. Tests

Add/extend unit tests that assert the POST body:

- `CreateSandboxFromImageParams(image="python:3.13-slim", cpu_arch="arm64")`
  with `DaytonaConfig(target="arm64-test-1", …)` → body contains
  `"region": "arm64-test-1"` and `"cpu_arch": "arm64"`.
- Params **without** `cpu_arch` → body has **no** `cpu_arch` key.
- Snapshot create path also forwards `cpu_arch` if placed on the base class.

Mock `HttpClient.post` / capture JSON; no live cluster required for the
unit test.

### 4. Docs / changelog

- Document `cpu_arch` on create params (quickstart / ARM64 region guide).
- Note: ARM64 target needs **both** `DaytonaConfig(target=..., toolbox_url=...)`
  **and** `cpu_arch="arm64"` on the create params.
- Bump package version and mention in changelog (breaking only in the sense
  of a new optional field — should be semver-compatible minor/patch).

---

## Acceptance

```python
client = Daytona(DaytonaConfig(
    target="arm64-test-1",
    toolbox_url="https://toolbox.arm64-test-1.rlp.trydaytona.com/toolbox",
))
sb = client.create(
    CreateSandboxFromImageParams(image="python:3.13-slim", cpu_arch="arm64"),
    timeout=120,
)
try:
    out = sb.process.exec(
        "python -c 'import platform; print(platform.machine())'",
        timeout=30,
    )
    assert out.result.strip() in ("aarch64", "arm64")
finally:
    client.delete(sb)
```

No `TypeError` on params; no `no matching capacity` from missing selector
(assuming the ARM64 pool actually has runners).

---

## Workaround (callers today)

Until the SDK ships this, callers must inject `cpu_arch` onto `POST /vms`
themselves (duplicate create body build, or wrap `HttpClient.post`). That is
what the Vera benchmark harness does temporarily; it should be deleted once
`rlp-sdk` exposes the field.

---

## Related context

- Server-side: resource-type selectors / queue
  `jobs.vm.create.arm64-test-1.arm64` (eng).
- Symptom without selector: `no matching capacity` within 60s on
  `arm64-test-1` even with correct `target` + toolbox URL.
