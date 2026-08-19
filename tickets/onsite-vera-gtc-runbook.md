# Onsite Vera / NVIDIA HQ runbook

**Goal:** Leave HQ with clean JSONL for Chart A (chip) and Chart B (density) on the **Vera RLP cell**. EDA + slides after. Default-region Daytona controls run **after** Vera time.

**Primary path (verified):** `--runner rlp --target vera` + **Docker Hub ARM64 images** as `--snapshot` (registry ref). No native RLP snapshot bake — Vera sandboxes have no PyPI DNS, so `build_rlp_snapshot.py` / in-cell `uv sync` fails.

**Related:** `tickets/gtc-berlin-vera-daytona-compelling-data.md`, `tickets/vera-rlp-smoke.md`, `tickets/onsite-vera-docker-runbook.md` (local Docker on a Vera node).

**How to use this doc:** every runnable command is on its **own line**. Copy/paste one at a time. Keep the SSH tunnel open in a separate terminal for all RLP commands.

---

## Hub images (ARM64)

| Pack | `--snapshot` (copy this) | Hub arm64 |
| ---- | ------------------------ | --------- |
| `rl` | `dtgraviet/vera-agent-benchmark-rl:latest` | yes (verified on Vera) |
| `analytics` | `dtgraviet/vera-agent-benchmark-analytics:latest` | yes (verified on Vera) |
| `agent` | `dtgraviet/vera-agent-benchmark:latest` | yes |
| `media` | `dtgraviet/vera-agent-benchmark-media:latest` | yes |
| `disk` | `dtgraviet/vera-agent-benchmark-disk:latest` | yes |
| `evals` | `dtgraviet/vera-agent-benchmark-evals:latest` | yes (`:6d21896`) |

Pin a digest/tag (e.g. `:fbcd016`) instead of `:latest` if you need bit-stable reruns.

JSONL lands under `data/<benchmark>/rlp-vera/`.

---

### Shared flags


| Flag | Meaning |
| ---- | ------- |
| `--runner rlp` | RLP sandboxes (onsite Vera cell) |
| `--target vera` | Vera cell — required on every onsite RLP command |
| `--snapshot <hub-ref>` | Docker Hub image (deps pre-baked). Not a native `/snapshots` name. |
| `UV_NO_SYNC=1` | Keep eng’s editable `rlp-sdk` (required for `cpu_type` / `region_routing`) |
| `--seed 42` | Fixed RNG so checksums match across runners |
| `--levels …` | Concurrent sandboxes. `1` = smoke; `1 8 22 44 88` = density ladder |
| `-E` / `--episodes-per-sandbox` | Jobs per sandbox. `-E 1` = density; `-E 8` = chip / warm reuse |


### Resource parity (CPU / RAM)

Harness pins **1 vCPU** and RAM from each benchmark’s `docker_memory`:

| Pack | RAM |
| ---- | --- |
| `rl`, `agent`, `evals` | 1 GiB |
| `media`, `disk` | 2 GiB |
| `analytics` | **4 GiB** (needed for `--n 200`) |

- **Docker:** `--memory=…` at run time  
- **RLP (Vera Hub + default snaps):** `Resources(memory=…)` at create time  
- **Daytona:** baked into the container snapshot at build time (rebuild after changing `docker_memory`)


`--n` is **work size inside one sandbox**. It means something different per pack — see below.

### Final run params by task

**Chart A — chip** (`duration_ms` only; ignore create tax)


| Pack | What `--n` means | Final params | Why |
| ---- | ---------------- | ------------ | --- |
| `rl` | Mocked rollout steps | `--levels 1 88 --n 5000 -E 8` | Heavy episode. `-E 8` so warm wall tracks chip, not create. |


**Chart B — density** (throughput + p99; fresh sandbox each job)


| Pack | What `--n` means | Final params | Why |
| ---- | ---------------- | ------------ | --- |
| `rl` | Mocked rollout steps | `--levels 1 8 22 44 88 --n 64 -E 1` | Light episode; packing many sandboxes. |
| `agent` | Repo-agent work units | `--levels 1 8 22 44 88 --n 20 -E 1` | Coding-agent–shaped density. |
| `evals` | TB-style trials inside one sandbox | `--levels 1 8 22 44 88 --n 1 -E 1` | One eval trial per sandbox. |


**Chart C — optional bandwidth** (only if time; keep if Vera wins on `duration_ms`)


| Pack | What `--n` means | Final params | Why |
| ---- | ---------------- | ------------ | --- |
| `analytics` | Synthetic table scale | `--levels 1 88 --n 200 -E 8` | DuckDB / mem-BW spike. |
| `media` | Frame scale (`frames = n × 90`) | `--levels 1 88 --n 40 -E 8` | FFmpeg h.264 sibling. |


**Eng / infra — disk**


| Pack | What `--n` means | Final params | Why |
| ---- | ---------------- | ------------ | --- |
| `disk` | MiB seq write + `n×64` small files | `--levels 1 8 22 44 88 --n 128 -E 1` | Sandbox disk under density. |


**Smokes (Day 1):** always `--levels 1 -E 1` with a small `--n` — wiring check only.

**Packs on Vera (all six):** `rl`, `agent`, `analytics`, `evals`, `media`, `disk`

### Graviton-comparable ladders (same shape as yesterday’s RL / analytics)

Use **one primary full ladder** per pack (`--levels 1 8 22 44 88`, `--seed 42`). Match Vera Docker chip `--n` where we already have baselines, so later Graviton5 runs are apples-to-apples on `duration_ms`.

| Pack | Role | Primary ladder (run this) | Why these flags | RAM |
| ---- | ---- | ------------------------- | --------------- | --- |
| `rl` | **done** chip | `n=5000 -E 8` | Chart A; warm reuse | 1 GiB |
| `analytics` | **done** BW | `n=200 -E 8` | Chart C; DuckDB | 4 GiB |
| `agent` | coding-agent chip | `n=200 -E 8` | Vera Docker chip used n=200 (~2.7 s); density n=20 is too light for chip | 1 GiB |
| `evals` | TB-style chip | `n=3 -E 8` | Vera Docker heavy n=3 (~5.3 s); Chart B density is n=1 | 1 GiB |
| `media` | BW / FFmpeg | `n=40 -E 8` | Chart C; Vera Docker ~15 s @ n=40 | 2 GiB |
| `disk` | FS / eng | `n=512 -E 1` | Vera Docker heavy n=512; **no `-E 8`** (FS reuse muddies the probe) | 2 GiB |

Optional Chart B density (after primary, if time):

| Pack | Density ladder |
| ---- | -------------- |
| `agent` | `n=20 -E 1` |
| `evals` | `n=1 -E 1` |
| `disk` | `n=128 -E 1` (eng density) |
| `media` | skip or `n=10 -E 1` (still multi-second) |

Copy/paste primaries (tunnel + eng SDK first):

```bash
UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark:latest --levels 1 8 22 44 88 --n 200 --seed 42 -E 8
```

```bash
UV_NO_SYNC=1 uv run main.py --benchmark evals --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark-evals:latest --levels 1 8 22 44 88 --n 3 --seed 42 -E 8
```

```bash
UV_NO_SYNC=1 uv run main.py --benchmark media --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark-media:latest --levels 1 8 22 44 88 --n 40 --seed 42 -E 8
```

```bash
UV_NO_SYNC=1 uv run main.py --benchmark disk --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark-disk:latest --levels 1 8 22 44 88 --n 512 --seed 42 -E 1
```

Smoke each pack once before its ladder (`--levels 1 -E 1`, small `--n`: agent 20, evals 1, media 1, disk 1).

---

## Day overview (3 days)


| Day | Focus |
| --- | ----- |
| **Day 1** | Tunnel + SDK, Hub images ready, smokes, inspect, short reuse smoke |
| **Day 2** | Chart A chip on Vera (`duration_ms`, `-E 8`) |
| **Day 3** | Chart B density on Vera (`E=1` ladder) + lock Berlin headline |


**After Vera time:** default-region Daytona controls + optional VM / Harbor.

---

## Before you start (prep / Day 0)

- [ ] Repo synced; sibling eng checkout at `../rlp` (for editable SDK)
- [ ] `.env` has `VERA_RLP_API_URL`, `VERA_RLP_API_KEY`, `VERA_RLP_TOOLBOX_URL` (localhost tunnel URLs)
- [ ] Hub ARM64 images exist for every pack you will run (at least `…-rl:latest`)
- [ ] You can open several terminals in this repo

### Terminal 1 — SSH tunnel (leave running)

```bash
ssh -N -L 8088:127.0.0.1:8088 -L 9000:127.0.0.1:9000 daytona@10.96.8.181
```

### Terminal 2 — host SDK (once per shell / after `uv sync`)

PyPI `rlp-sdk` lacks `region_routing` / `cpu_type`. Always install eng’s editable SDK, then keep `UV_NO_SYNC=1` on every Vera command (plain `uv sync` / `uv run` without it reverts to PyPI).

```bash
cd /Users/danielgraviet/Desktop/projects/arm64-benchmark-1
```

```bash
UV_NO_SYNC=1 uv pip install -e ../rlp/clients/python
```

```bash
UV_NO_SYNC=1 uv run python -c "from rlp import DaytonaConfig; assert 'region_routing' in DaytonaConfig.__dataclass_fields__; print('eng rlp-sdk OK')"
```

```bash
curl -m 5 -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8088/
```

Expect `401` (API up, unauthenticated health) or `200`. If curl hangs/fails, fix the tunnel before any harness run.

**If you see** `Installed rlp-sdk lacks DaytonaConfig.region_routing` — re-run the `uv pip install -e` line above, then retry with `UV_NO_SYNC=1`.

Quick wiring smoke (copy/paste after SDK + tunnel):

```bash
UV_NO_SYNC=1 uv run main.py --benchmark rl --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark-rl:latest --levels 1 --n 64 --seed 42 -E 1
```

**Prefix every Vera harness command with `UV_NO_SYNC=1`.**

---

## Day 1 — Hub images + smoke + inspect

### 1a. Confirm Hub pulls (optional on laptop; RLP runners pull on create)

```bash
docker pull dtgraviet/vera-agent-benchmark-rl:latest
```

```bash
docker pull dtgraviet/vera-agent-benchmark:latest
```

```bash
docker pull dtgraviet/vera-agent-benchmark-analytics:latest
```

```bash
docker pull dtgraviet/vera-agent-benchmark-evals:latest
```

```bash
docker pull dtgraviet/vera-agent-benchmark-media:latest
```

```bash
docker pull dtgraviet/vera-agent-benchmark-disk:latest
```

If a pull 404s, build/push that Dockerfile’s arm64 image before the matching smoke. Do **not** run `scripts/build_rlp_snapshot.py --target vera` (cell cannot reach PyPI).

### 1b. SDK smoke (optional wiring)

```bash
UV_NO_SYNC=1 uv run python scripts/vera_rlp_smoke.py
```

### 1c. Harness smokes on Vera (c=1, sequential)

```bash
UV_NO_SYNC=1 uv run main.py --benchmark rl --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark-rl:latest --levels 1 --n 64 --seed 42 -E 1
```

```bash
UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark:latest --levels 1 --n 20 --seed 42 -E 1
```

```bash
UV_NO_SYNC=1 uv run main.py --benchmark analytics --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark-analytics:latest --levels 1 --n 5 --seed 42 -E 1
```

```bash
UV_NO_SYNC=1 uv run main.py --benchmark evals --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark-evals:latest --levels 1 --n 1 --seed 42 -E 1
```

```bash
UV_NO_SYNC=1 uv run main.py --benchmark media --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark-media:latest --levels 1 --n 1 --seed 42 -E 1
```

```bash
UV_NO_SYNC=1 uv run main.py --benchmark disk --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark-disk:latest --levels 1 --n 1 --seed 42 -E 1
```

### 1d. Sandbox-reuse smoke (Chart A plumbing)

```bash
UV_NO_SYNC=1 uv run main.py --benchmark rl --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark-rl:latest --levels 1 --n 1000 --seed 42 -E 4
```

### Task: inspect before Day 2

Open the newest JSONL under `data/<bench>/rlp-vera/`.

- [ ] Exit 0 / `failures: 0` / `checksum_ok: true`
- [ ] Run rows have `duration_ms` > 0
- [ ] Reuse smoke: `episode_idx` 0…3, only idx 0 has `"cold": true`, checksums match across episodes
- [ ] `meta.env` / arch probe shows `aarch64` (or `arm64`)
- [ ] Log line shows `app_dir=/app` (Hub image layout)

**Stop if anything looks off.** Fix before Day 2.

---

## Day 2 — Chart A main evaluation loop (Vera only, sequential)

Same heavy RL episode on **Vera**. Compare `duration_ms` **only** for the chip claim. `-E 8` warms the sandbox so wall latency on warm episodes tracks compute.

Do **not** burn Vera time on default-region Daytona controls — run those after.

```bash
UV_NO_SYNC=1 uv run main.py --benchmark rl --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark-rl:latest --levels 1 88 --n 5000 --seed 42 -E 8
```

Optional Chart C on Vera (only if time; keep only if Vera wins on `duration_ms`):

```bash
UV_NO_SYNC=1 uv run main.py --benchmark analytics --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark-analytics:latest --levels 1 88 --n 200 --seed 42 -E 8
```

```bash
UV_NO_SYNC=1 uv run main.py --benchmark media --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark-media:latest --levels 1 88 --n 40 --seed 42 -E 8
```

**Pass if:** Vera `duration_ms` p50 is strong vs the control you’ll run later (≥20–30%).  
**Else:** drop chip brag; still keep files for density day.

---

## Day 3 — Chart B density + lock slide (Vera only, sequential)

Light workloads, full ladder, `-E 1` (one create per sandbox — this is density, not reuse).

```bash
UV_NO_SYNC=1 uv run main.py --benchmark rl --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark-rl:latest --levels 1 8 22 44 88 --n 64 --seed 42 -E 1
```

```bash
UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark:latest --levels 1 8 22 44 88 --n 20 --seed 42 -E 1
```

```bash
UV_NO_SYNC=1 uv run main.py --benchmark evals --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark-evals:latest --levels 1 8 22 44 88 --n 1 --seed 42 -E 1
```

If time remains on Vera, optional density siblings:

```bash
UV_NO_SYNC=1 uv run main.py --benchmark disk --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark-disk:latest --levels 1 8 22 44 88 --n 128 --seed 42 -E 1
```

```bash
UV_NO_SYNC=1 uv run main.py --benchmark analytics --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark-analytics:latest --levels 1 8 22 44 88 --n 10 --seed 42 -E 1
```

```bash
UV_NO_SYNC=1 uv run main.py --benchmark media --runner rlp --target vera --snapshot dtgraviet/vera-agent-benchmark-media:latest --levels 1 8 22 44 88 --n 40 --seed 42 -E 1
```

### After Vera runs — EDA

```bash
uv run python eda.py --benchmark rl
```

```bash
uv run python eda.py --benchmark agent
```

```bash
uv run python eda.py --benchmark analytics
```

```bash
uv run python eda.py --benchmark evals
```

```bash
uv run python eda.py --benchmark media
```

```bash
uv run python eda.py --benchmark disk
```

---

## After Vera time — default-region Daytona controls

Run these **after** the onsite window so Chart A / B can be compared Vera vs today’s Daytona without burning node time. (Daytona path still uses `build_daytona_snapshot.py` + `--runner daytona` — no Hub `--snapshot`.)

```bash
uv run scripts/build_daytona_snapshot.py --benchmark rl
```

```bash
uv run main.py --benchmark rl --runner daytona --levels 1 88 --n 5000 --seed 42 -E 8
```

```bash
uv run main.py --benchmark rl --runner daytona --levels 1 8 22 44 88 --n 64 --seed 42 -E 1
```

```bash
uv run main.py --benchmark agent --runner daytona --levels 1 8 22 44 88 --n 20 --seed 42 -E 1
```

```bash
uv run main.py --benchmark evals --runner daytona --levels 1 8 22 44 88 --n 1 --seed 42 -E 1
```

Optional Chart C / disk controls:

```bash
uv run main.py --benchmark analytics --runner daytona --levels 1 88 --n 200 --seed 42 -E 8
```

```bash
uv run main.py --benchmark media --runner daytona --levels 1 88 --n 40 --seed 42 -E 8
```

```bash
uv run main.py --benchmark disk --runner daytona --levels 1 8 22 44 88 --n 128 --seed 42 -E 1
```

---

## Optional — Daytona Linux VM vs container (us-west-3, after Vera)

Same workloads. Eng: VM seeds live in `us-west-3` (not default `us`).
Builder writes **cold** (`vera-*-benchmark-vm`) and **hot memory** (`vera-*-benchmark-vm-hot`) snaps.


| Series | Runner | Boot |
| ------ | ------ | ---- |
| `daytona` | `--runner daytona` | container |
| `daytona-vm` | `--runner daytona-vm` | VM cold disk |
| `daytona-vm-hot` | `--runner daytona-vm-hot` | VM hot/memory |


```bash
uv run scripts/build_daytona_snapshot.py --benchmark media --class linux-vm
```

```bash
uv run scripts/build_daytona_snapshot.py --benchmark disk --class linux-vm
```

```bash
uv run main.py --benchmark media --runner daytona-vm --levels 1 --n 1 --seed 42 -E 1
```

```bash
uv run main.py --benchmark media --runner daytona-vm-hot --levels 1 --n 1 --seed 42 -E 1
```

```bash
uv run main.py --benchmark media --runner daytona-vm --levels 1 8 22 44 88 --n 40 --seed 42 -E 1
```

```bash
uv run main.py --benchmark media --runner daytona-vm-hot --levels 1 8 22 44 88 --n 40 --seed 42 -E 1
```

Disk axis (sandbox local FS — not media/CPU BW). Eng ladder `--n 128`:

```bash
uv run main.py --benchmark disk --runner daytona-vm --levels 1 --n 1 --seed 42 -E 1
```

```bash
uv run main.py --benchmark disk --runner daytona-vm-hot --levels 1 --n 1 --seed 42 -E 1
```

```bash
uv run main.py --benchmark disk --runner daytona-vm --levels 1 8 22 44 88 --n 128 --seed 42 -E 1
```

```bash
uv run main.py --benchmark disk --runner daytona-vm-hot --levels 1 8 22 44 88 --n 128 --seed 42 -E 1
```

---

## Optional — Harbor TB oracle (Phase 2, after density)

Not Day-1 P0. Requires `uv tool install 'harbor[daytona]'` and `DAYTONA_API_KEY`.
Do **not** use `--runner docker` for real Terminal-Bench.

```bash
uv run main.py --benchmark tbench --runner harbor --levels 5 --n 5
```

```bash
uv run main.py --benchmark tbench --runner harbor --levels 32 --n 0
```

Compare wall time-to-finish / JSONL under `data/tbench/harbor/`. Oracle pass rate should be ≈1.0. Details: `tickets/evals-terminal-bench-style.md`.

### Lock the Berlin sentence

- [ ] If Chart A wins clearly → lead with **chip + density**
- [ ] If A flat/noisy but B strong → lead with **RLP scales on Vera**
- [ ] Never headline light-`n` create/API latency as “Vera cores are faster”
- [ ] Don’t use `arm64-test-1` as Vera chip proof

> On Vera, RLP runs **88 concurrent** customer rollouts with **stable per-episode CPU**, and those episodes finish **___% faster** than on today’s region *(only if Chart A supports it)*.

---

## Quick read guide


| Chart | Look at | Ignore for the claim |
| ----- | ------- | -------------------- |
| A (chip) | `duration_ms` p50/p99; warm `p50_warm_ms` as cross-check | cold create `latency_ms` |
| B (density) | `throughput_per_sec`, `p99_ms`; flat `duration_ms` at 88 | reuse / `-E>1` |


---

## Anti-goals

- Don’t start Day 2 before Day 1 inspect is green
- Don’t run Chart B with `-E > 1` and call it density
- Don’t spray every `--n` on every bench during Vera time
- Don’t burn Vera time on default-region controls (do those after)
- Don’t decide the GTC headline from wall `latency_ms` alone
- Don’t run `build_rlp_snapshot.py --target vera` (no PyPI egress on the cell)
- Don’t omit `UV_NO_SYNC=1` after installing the editable eng SDK
- Don’t omit `--snapshot dtgraviet/…` on RLP Vera (defaults look for a missing native snap)
