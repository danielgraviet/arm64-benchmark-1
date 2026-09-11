# Coding agent: normal RLP over API (not Vera)

**For:** an agent (or human) running a **different** test against the default / public RLP API  
**Not for:** the NVIDIA Vera onsite cell (`--target vera`, Axis SSH, `UV_NO_SYNC`, eng SDK overlay)  
**Date:** 2026-09-05

Vera client handoff lives in `tickets/eng-vera-node-client-ready.md`. Ignore that file for this path.

---

## What you need

| Item | Value |
| ---- | ----- |
| SDK | PyPI `rlp-sdk` (e.g. `0.3.2`). No editable eng checkout. No `UV_NO_SYNC`. |
| Env | `RLP_API_URL` + `RLP_API_KEY` in `.env` or the process environment |
| Client | Laptop or any host with HTTPS to the RLP API. No Axis jump. |

```dotenv
RLP_API_URL=https://<your-default-rlp-api-host>
RLP_API_KEY=<key>
```

Do **not** set `VERA_RLP_*`. Do **not** point `RLP_TOOLBOX_URL` at an x86 toolbox if you then create sandboxes in another region.

---

## Minimal create + exec (default region)

```python
from rlp import CreateSandboxFromImageParams, Daytona, DaytonaConfig

# Empty config → SDK reads RLP_API_URL / RLP_API_KEY from the environment.
client = Daytona(DaytonaConfig())

sandbox = client.create(
    CreateSandboxFromImageParams(image="python:3.13-slim"),
    timeout=60,
)
try:
    result = sandbox.process.exec(
        "python -c 'import platform; print(platform.machine())'",
        timeout=30,
    )
    print(result.result)
    if result.exit_code != 0:
        raise RuntimeError(f"exit {result.exit_code}")
finally:
    client.delete(sandbox)
```

```bash
uv add 'rlp-sdk==0.3.2'
uv run --env-file .env python your_script.py
```

Replace the `exec` string with whatever test command you need.

---

## Optional: named public targets (still API, still not Vera)

Only if the test must land on a specific cell. Pass `target` + matching toolbox. Credentials stay `RLP_API_KEY` unless a cell-specific override exists.

| Target | When | Notes |
| ------ | ---- | ----- |
| (omit / default) | Normal x86 fleet | `DaytonaConfig()` |
| `arm64-test-1` | Graviton ARM64 test region | Set `toolbox_url` to `https://toolbox.arm64-test-1.rlp.trydaytona.com/toolbox`. See `tickets/CONTEXT-rlp-arm64-implementation.md`. |
| `us-phoenix-1` | Phoenix Zen5 cell | Own API host `https://api.us-phoenix-1.rlp.trydaytona.com`. Boot Hub images, not west-1 NFS snaps. |
| `redswitches` | Redswitches cell | Own API host `https://api.redswitches.rlp.trydaytona.com`. |

Example ARM64 (not Vera):

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
    timeout=60,
)
```

---

## Using this repo’s harness (optional)

If the other test is one of our packs and you only need default-region RLP:

```bash
# from arm64-benchmark-1, with RLP_API_URL + RLP_API_KEY in .env
uv sync
uv run main.py --benchmark <pack> --runner rlp --levels 1 --n <n> --seed 42 -E 1
```

No `--target vera`. No `UV_NO_SYNC`. Results under `data/<pack>/rlp/` (or `rlp-x86/` naming as configured).

---

## Do not do (Vera-only traps)

- SSH to `vera-axis` / `ipp8-*-vera-*`
- `UV_NO_SYNC=1` or `uv pip install -e ../rlp/clients/python`
- `VERA_RLP_API_URL=http://127.0.0.1:8088`
- `--target vera` / `cpu_type=vera` / `region_routing=False` for this unrelated test

Those are for the onsite Vera cell only.

---

## Quick failure hints

| Symptom | Fix |
| ------- | --- |
| 401 / auth | Check `RLP_API_KEY` and that it matches `RLP_API_URL` |
| Wrong arch (`x86_64` when you wanted ARM) | Pass `target=arm64-test-1` + ARM toolbox URL |
| HTTP 409 posting a cell region to the default API | Use that cell’s own `api_url` (Phoenix / redswitches), not the default host |
| `region_routing` / eng SDK errors | You are on the Vera path by mistake. Drop eng overlay and use PyPI + `RLP_*` only |

---

## RLP SDK fixes we already hit (give this to agents)

These are real bugs / gaps between PyPI `rlp-sdk` and what the native `/vms` API expects. Eng’s newer Python client (editable `~/rlp/clients/python`) has most of them. If creates mis-size RAM, land on the wrong region, or toolbox URLs break, check this list before blaming the runner.

### 1. CamelCase vs snake_case toolbox URL

API responses are inconsistent:

- native detail DTO: `toolbox_proxy_url` (snake_case)
- `/daytona` facade DTO: `toolboxProxyUrl` (camelCase)
- native `GET /vms` list rows: often **neither**

**Fix in SDK** (`Daytona._resolve_toolbox_url`): accept both keys, and do not fail `list()` when the URL is missing. Raise only when toolbox (`process.exec` / fs) is actually used.

```python
return self._toolbox_url or vm.get("toolbox_proxy_url") or vm.get("toolboxProxyUrl") or None
```

### 2. Memory must be `mem_mib`, and fractional GiB must round

`Resources.memory` / `.disk` are **GiB** (Daytona semantics). Native `POST /vms` wants **`mem_mib` / `scratch_mib`**.

Older SDK sent raw `memory` / `disk` keys. The API **silently ignored** them (everyone got the 1 GiB default). After `deny_unknown_fields`, those keys became hard failures.

**Wrong** (truncates 0.5 GiB to 0 → HTTP 400):

```python
body["mem_mib"] = int(r.memory) * 1024   # int(0.5)*1024 == 0
```

**Right** (512 MiB max-pack):

```python
body["mem_mib"] = int(round(float(r.memory) * 1024))  # 0.5 → 512
body["scratch_mib"] = int(r.disk) * 1024
```

Harness flag `--rlp-memory 0.5` means **0.5 GiB**, not 512 GiB. Never pass `--rlp-memory 512` unless you want half a tebibyte.

### 3. Forward `DaytonaConfig.target` as native `region` on create

Without this, the SDK dropped `target` and every create fell back to the **default x86** region no matter what you configured.

```python
if self._target and self._target.strip().lower() != "local":
    body["region"] = self._target
```

Dedicated cells (Phoenix / redswitches) also need their **own** `api_url`. Posting `us-phoenix-1` to the default API returns HTTP 409.

### 4. Placement fields PyPI may lack (`region_routing`, `cpu_arch`, `cpu_type`)

Needed for Vera / ARM routing. PyPI `rlp-sdk` often has none of these. Eng editable SDK does.

- `region_routing=False` pins requests to the cell `api_url`
- `cpu_arch=arm64` / `cpu_type=vera` on create for Vera placement

That is why Vera client work uses `UV_NO_SYNC=1 uv pip install -e ../rlp/clients/python`. Default-region API tests usually do **not** need this.

### 5. Burst cap field names (`cpu_max` vs `vcpus_max`)

Eng API maps burst CPU to `vcpus_max`. SDK checkouts disagree on the Python field name (`cpu_max`, `vcpus_max`, `max_cpu`). This repo’s harness probes whatever the installed SDK exposes (`harness/rlp_create.py`) so `--rlp-cpu-max` keeps working across checkouts.

### How to verify the memory fix on any host

```bash
UV_NO_SYNC=1 uv run python -c "
from rlp import Resources
r = Resources(cpu=0.125, memory=0.5, disk=2)
print('mem_mib', int(round(float(r.memory) * 1024)))  # expect 512
import rlp.daytona as d, pathlib
print(pathlib.Path(d.__file__))
print([l for l in pathlib.Path(d.__file__).read_text().splitlines() if 'mem_mib' in l])
"
```

If you still see `int(r.memory) * 1024` with no `round`, patch or upgrade the SDK before running 512 MiB ladders.

---

## Blocker that is NOT an SDK patch: `process.exec` → 404 on guest `rlp-rs`

If create works but:

```text
sandbox.process.exec(...) → 404 route not found
guest / daemon version mentions rlp-rs-0.5.2 (or similar)
```

that is the **in-guest daemon**, not the Python SDK patches above.

Call path:

```text
SDK process.exec
  → POST {toolbox_url}/{vm_id}/process/execute   (toolbox proxy)
    → forward into the VM’s rlp-rs / daytona daemon
      → daemon must register POST /process/execute
```

| Status | Meaning | Whose bug |
| ------ | ------- | --------- |
| SDK / create OK, exec **404 route not found** | Guest daemon binary or image lacks that route (or wrong daemon is listening) | Platform / image / `rlp-rs` build |
| Exec **401** | Toolbox proxy authz (wrong `RLP_API_URL` on the proxy, cell never got the exec-401 fix) | Cell proxy config. See eng `SESSION-IMAGES-GC-DEPLOY.md` arm64-test-1 notes |
| Create **400** on `mem_mib=0` | SDK memory rounding (fix #2 above) | SDK |
| Wrong arch / wrong region | `target` / `region` / cell `api_url` (fixes #3–4) | SDK + config |

**What the other agent should do**

1. Stop chasing camelCase / `mem_mib` / `UV_NO_SYNC` for this 404.
2. Ask eng: which `rlp-rs` / golden snapshot on this cell actually serves `POST /process/execute`?
3. Prefer a known-good Hub boot image on a cell where exec already works (this repo’s agent path uses `dtgraviet/vera-agent-benchmark:v3` on Phoenix / Vera / redswitches). A bare `python:3.13-slim` create may boot a VM whose guest daemon is incomplete for toolbox exec.
4. Prove without the SDK:

```bash
# after create, with the same key + toolbox host the SDK uses
curl -sS -X POST "$TOOLBOX/toolbox/$VM_ID/process/execute" \
  -H "Authorization: Bearer $RLP_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"command":"uname -a"}'
```

If curl also 404s, it is the guest daemon. If curl 200s and only the SDK fails, then revisit SDK routing / toolbox base URL.
