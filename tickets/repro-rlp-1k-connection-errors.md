# Repro: RLP errors at 1k concurrent creates

**Audience:** eng  
**When:** 13 Aug 2026, default RLP region (x86, no region override)  
**Workload:** short in-sandbox eval (~2–3s) on a prebuilt snapshot; one fresh sandbox per request

## What we saw

`c=1` and `c=100`: 0 failures.

`c=1000`: **157 / 1000 failed** (~16%) on the first pass; **114 / 1000** (~11%) on a re-run the same day. Errors were all on **create**, not the in-sandbox job.

| Count (first pass) | Error |
|---|---|
| 135 | `DaytonaConnectionError: Server disconnected without sending a response.` |
| 22 | `DaytonaConnectionError: [Errno 54] Connection reset by peer` |

---

## Setup

### Client

- **rlp-sdk** Daytona-compatible client (`from rlp import Daytona`)
- Auth via normal RLP env (`RLP_API_KEY` / `RLP_API_URL` or equivalent)
- **Default RLP region** (x86). Do **not** pass a custom `target` / ARM64 region.

### Snapshot

- Named snapshot: `vera-evals-benchmark`
- Resolved at create time to native image id (our run: `snap-3b72dd7e-2f03-489b-bebd-626d4b03cdf3`)
- Any small offline snapshot that boots and can run a ~2s command is fine; the failure mode is on create, not the payload.

### Concurrency pattern

For concurrency `N` (repro with `N=1000`):

1. Open a thread pool with **`max_workers=N`** (we use `concurrent.futures.ThreadPoolExecutor`).
2. Submit **N workers in parallel**. Each worker does, independently:
   1. **Create** sandbox from the snapshot (create timeout ~120s)
   2. **Exec** one short command inside the sandbox (optional for repro — failures happen at step 1)
   3. **Delete** the sandbox
3. Collect successes vs create exceptions.

There is **no** create-rate pacing, batching, or retry. All N creates are issued as fast as the client can open HTTP connections.

Pseudocode:

```text
with ThreadPoolExecutor(max_workers=1000) as pool:
    futures = [pool.submit(create_exec_delete) for _ in range(1000)]
    wait for all
```

`create_exec_delete`:

```text
try:
    sandbox = client.create(from_snapshot=vera-evals-benchmark, ephemeral=True, ...)
    # optional: sandbox.process.exec("short command")
finally:
    client.delete(sandbox)  # if create succeeded
```

### Control runs

| N | Expected |
|---|---|
| 1 | clean |
| 100 | clean |
| 1000 | ~10–16% create failures as above |

### What to look for

- Exception on **create**, before exec
- Dominant string: `Server disconnected without sending a response`
- Secondary: `Connection reset by peer`
- Successful sandboxes still complete the short job normally (~2–3s in-sandbox)

### Notes

- Same pattern against **Daytona prod** with raised limits still fails at 1k, but mostly with `Connection reset by peer` / connection errors (not the old CPU-cap / 429 mix).
- This is a **burst of 1000 concurrent creates**, not 1000 sandboxes held idle over time.
