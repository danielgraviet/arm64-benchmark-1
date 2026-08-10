# RLP: friendly snapshot name cannot boot VMs (NFS manifest mismatch)

**Status:** Open  
**Product:** rl-platform (RLP) + `rlp-sdk` (Python)  
**Severity:** High — blocks API-driven create-from-snapshot; web UI works  
**Date:** 2026-08-10  
**Reporter:** arm64-benchmark / Vera agent concurrency harness  

---

## Summary

Creating a sandbox from a **native disk snapshot** via the Python SDK fails when the friendly snapshot name is passed as `image` / `snapshot`. The same snapshot boots successfully from the RLP web UI.

The control plane looks up an OCI/NFS manifest named exactly like the friendly name (e.g. `vera-agent-benchmark`) and returns:

```text
manifest "vera-agent-benchmark" not found on NFS
```

The bootable ref is actually the snapshot’s `manifest_name` (e.g. `snap-9f647e74-ee19-4864-ad9c-69ac751504b6`).

---

## Environment

- API: `https://api.rl.trydaytona.com` (`RLP_API_URL`)
- Toolbox: `https://toolbox.rl.trydaytona.com/toolbox` (`RLP_TOOLBOX_URL`)
- SDK: `rlp-sdk==0.3.2`
- Base builder image: `ghcr.io/astral-sh/uv:python3.13-bookworm-slim`
- Snapshot created with: `Sandbox.create_snapshot("vera-agent-benchmark", kind="disk")`

---

## Two different “snapshot” surfaces

| Surface | Route | What it is | Example |
|---|---|---|---|
| Daytona-dialect image alias | `GET /daytona/snapshots` | OCI/NFS image alias | `vedran-test-snapshot-…` → `python:3.13-slim` |
| Native VM disk snapshot | `GET /snapshots` | Disk capture from a running VM | `vera-agent-benchmark` → `manifest_name: snap-<uuid>` |

`Sandbox.create_snapshot()` writes to the **native** `/snapshots` API (what the web UI lists).  
`Daytona.create(CreateSandboxFromSnapshotParams(snapshot="…"))` sends that string as `POST /vms` `image`, which is resolved as an **NFS/OCI manifest**, not as a native snapshot name lookup.

---

## Reproduction

### 1. Create a native snapshot (works)

```python
from rlp import Daytona, DaytonaConfig, CreateSandboxFromImageParams

client = Daytona(DaytonaConfig())  # uses RLP_API_KEY / RLP_API_URL / RLP_TOOLBOX_URL
sb = client.create(
    CreateSandboxFromImageParams(image="ghcr.io/astral-sh/uv:python3.13-bookworm-slim"),
    timeout=300,
)
# … configure filesystem …
result = sb.create_snapshot("vera-agent-benchmark", kind="disk")
# result ≈ {"snapshot_id": "…", "job_id": "…"}
# Web UI shows vera-agent-benchmark as ready.
```

### 2. Confirm native snapshot exists

```python
snaps = client._api.get("/snapshots").json()["snapshots"]
# finds:
# {
#   "id": "9f647e74-ee19-4864-ad9c-69ac751504b6",
#   "name": "vera-agent-benchmark",
#   "manifest_name": "snap-9f647e74-ee19-4864-ad9c-69ac751504b6",
#   "status": "ready",
#   "kind": "disk",
#   ...
# }
```

### 3. Confirm Daytona-dialect alias does **not** exist

```python
client.snapshot.get("vera-agent-benchmark")
# → DaytonaNotFoundError: snapshot 'vera-agent-benchmark' not found

client.snapshot.list()
# → does not include vera-agent-benchmark
```

### 4. SDK create with friendly name fails

```python
from rlp import CreateSandboxFromSnapshotParams

client.create(CreateSandboxFromSnapshotParams(snapshot="vera-agent-benchmark"), timeout=60)
# → DaytonaError: … reason=manifest "vera-agent-benchmark" not found on NFS
```

Same failure with:

```python
CreateSandboxFromImageParams(image="vera-agent-benchmark")
```

### 5. Web UI create from the same snapshot succeeds

Manual “create sandbox from `vera-agent-benchmark`” in the RLP UI boots successfully.

### 6. SDK create with `manifest_name` succeeds

```python
client.create(
    CreateSandboxFromImageParams(
        image="snap-9f647e74-ee19-4864-ad9c-69ac751504b6"
    ),
    timeout=60,
)
# → started/running; filesystem contents from the disk snapshot are present
```

Passing raw snapshot `id` (without `snap-` prefix) fails with the same NFS error.

---

## Expected behavior

One of:

1. **SDK resolve:** `CreateSandboxFromSnapshotParams(snapshot="vera-agent-benchmark")` looks up native `/snapshots` by `name` and boots using `manifest_name`, **or**
2. **API accept friendly name:** `POST /vms` with `image: "vera-agent-benchmark"` resolves native ready snapshots by name, **or**
3. **Documented contract:** docs/SDK clearly state that native snapshots must be booted via `manifest_name`, and the SDK exposes a first-class helper (e.g. `resolve_snapshot("vera-agent-benchmark")` → `snap-<uuid>`).

Today the web UI and the SDK disagree on the create contract.

---

## Actual behavior

- UI: boots from friendly name.
- SDK: treats friendly name as NFS manifest → error.
- `Daytona.snapshot.get/list` never see native disk snapshots, so waiters polling those routes hang forever even after the UI shows “ready”.

---

## Impact

Any automation that:

1. Builds an environment with `sandbox.create_snapshot("my-name")`
2. Later recreates workers with `CreateSandboxFromSnapshotParams(snapshot="my-name")`

…fails unless it privately reimplements native `/snapshots` listing and substitutes `manifest_name`.

---

## Workaround (current)

```python
snaps = client._api.get("/snapshots").json()["snapshots"]
snap = next(s for s in snaps if s["name"] == "vera-agent-benchmark" and s["status"] == "ready")
client.create(CreateSandboxFromImageParams(image=snap["manifest_name"]))
```

Wait for readiness on **`GET /snapshots`** (`status == "ready"`), not `GET /daytona/snapshots`.

---

## Related secondary issue (same session)

`sandbox.fs.upload_file(bytes, path)` returns **HTTP 400** for all paths tried (`/tmp/…`, `/root/…`, `/home/daytona/…`, relative) on sandboxes started from `ghcr.io/astral-sh/uv:python3.13-bookworm-slim`. `process.exec` works. We worked around uploads with base64-over-exec. Happy to file separately if useful; primary ticket is the snapshot boot mismatch.

---

## Ask for eng

1. Is the intended public create API `image=<manifest_name>` only?
2. Can `CreateSandboxFromSnapshotParams(snapshot=<friendly name>)` resolve native snapshots?
3. Can `/daytona/snapshots` include or link native disk snapshots so SDK waiters don’t hang?
4. Please align web UI create path with the documented SDK path (or document the dual model explicitly).
