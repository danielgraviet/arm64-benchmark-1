# RLP: ARM64 region `arm64-test-1` — create job not picked up (no matching capacity)

**Status:** Open  
**Product:** rl-platform (RLP) + `rlp-sdk` (Python)  
**Severity:** High — blocks building/running workloads on the ARM64 test region  
**Date:** 2026-08-10  
**Reporter:** Daniel Graviet (Vera agent concurrency benchmark)  
**Assignee / ping:** @Vedran Jukic  

---

## Summary

Creating a sandbox on the ARM64 target `arm64-test-1` fails during start with:

```text
rlp.errors.DaytonaError: Sandbox <id> failed to start
(state=error, reason=create job not picked up by any runner within 60s (no matching capacity))
```

This blocks building a native disk snapshot on ARM64 (Graviton) for a concurrency benchmark we are running across Docker / Daytona / default-region RLP / E2B / ARM64 RLP.

The client is constructed with the known-good ARM64 settings (explicit `target` + region-specific `toolbox_url` on `DaytonaConfig`). The failure looks like **scheduler / runner capacity on `arm64-test-1`**, not a misconfigured toolbox or wrong image arch — create never gets far enough to exec or run `platform.machine()`.

---

## Environment

| Setting | Value |
| --- | --- |
| Target | `arm64-test-1` |
| Toolbox | `https://toolbox.arm64-test-1.rlp.trydaytona.com/toolbox` |
| API | Same `RLP_API_URL` / `RLP_API_KEY` that work for default-region RLP |
| SDK | `rlp-sdk==0.3.2` |
| Images attempted | `python:3.13-slim` and `ghcr.io/astral-sh/uv:python3.13-bookworm-slim` |
| Host | macOS ARM64 |

`RLP_TOOLBOX_URL` was **not** left set to the default x86 toolbox for these creates. The ARM64 toolbox URL is passed directly into `DaytonaConfig`.

---

## Reproduction

```python
from rlp import CreateSandboxFromImageParams, Daytona, DaytonaConfig

client = Daytona(
    DaytonaConfig(
        target="arm64-test-1",
        toolbox_url="https://toolbox.arm64-test-1.rlp.trydaytona.com/toolbox",
    )
)

sandbox = client.create(
    CreateSandboxFromImageParams(image="python:3.13-slim"),
    timeout=120,
)
# Fails in wait_until_started with "no matching capacity" (~60s).
```

Observed sandbox IDs from failed creates:

- `2ff5a373-731e-449b-8f86-356cc048fd0f`
- `986044c2-4a3d-40cf-bb42-693876a25a8b`

Retried twice about a minute apart; same error both times.

---

## What we already ruled out (client side)

1. **Wrong region / sticky x86 toolbox** — create used:
   ```text
   target='arm64-test-1'
   toolbox_url='https://toolbox.arm64-test-1.rlp.trydaytona.com/toolbox'
   ```
2. **Image arch** — never reached; create fails before any exec.
3. **Leaked / competing sandboxes from us** — failure happens on the first create for the region in a fresh process.

Default-region RLP (no `target`, default toolbox) continues to work with the same API key for create + native disk snapshot + concurrency runs.

---

## Ask

1. Is `arm64-test-1` currently expected to have runnable capacity for this API key / project?
2. If capacity is intermittent, what is the intended wait / retry window, and can the control-plane error surface something more actionable than a 60s “no matching capacity”?
3. Once capacity is available, please confirm we can create a sandbox on `arm64-test-1` and then take a **native** disk snapshot on that region’s NFS (snapshots are per-region; we cannot reuse a default-region snapshot manifest on ARM64).

---

## Goal

Unblock ARM64 RLP so we can:

1. Create a sandbox on `arm64-test-1` from a multi-arch image (e.g. `python:3.13-slim`).
2. Confirm `platform.machine()` is `aarch64` / `arm64`.
3. Build a native disk snapshot on that region and run parallel create/exec/delete workers against it for latency/throughput comparison with other backends.
