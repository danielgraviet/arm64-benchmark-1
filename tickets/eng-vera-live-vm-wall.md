# Eng agent brief: Vera live-sandbox wall (~710)

**Audience:** eng / RLP agents debugging create capacity on the NVIDIA Vera cell  
**Date:** 2026-08-26  
**Cell:** `ipp8-d15-c2-vera-2` (on-node client → `http://127.0.0.1:8088`)  
**Reporter:** Daniel Graviet (arm64-benchmark-1)

---

## One-line ask

We can pack agent sandboxes cleanly through **concurrency 704**, but above that every extra create dies with a **60s runner pickup timeout**. Live fleet plateaus at **~709–710** regardless of requested concurrency. Please find and raise the binding **live-VM / create-admission** cap so we can test toward the fractional-CPU math ceiling (~2.7k at `cpu=0.125`).

---

## What we are measuring

| Item | Value |
|------|--------|
| Repo | `arm64-benchmark-1` (this tree on the Vera box: `~/arm64-benchmark-1`) |
| Benchmark | `agent` / `repo-agent-v3` |
| Image | `dtgraviet/vera-agent-benchmark:v3` |
| Recipe | `--n 50 --seed 42 -E 8 --hold-then-exec --rlp-cpu 0.125 --rlp-cpu-max 1` |
| Client | On-node only (not laptop SSH tunnel) |
| Series dir | `data/agent/rlp-vera-c0p125-max1/` |

`--rlp-cpu-max 1` makes the harness **omit `mode=dedicated`** so creates are burstable. Plain `--rlp-cpu 0.125` alone still dedicated-modes and hits ~348 Class B on Vera — that is a **different** wall. This ticket is about the **~710 live** wall under burst.

---

## Error you will see

```text
DaytonaError: Sandbox <id> failed to start
(state=error, reason=create job not picked up by any runner within 60s
 (no matching capacity))
```

| Field | Observed |
|-------|----------|
| Client `exit_code` | **-1** |
| Timing | ~60s (API create max queue; `RLP_CREATE_MAX_QUEUE_SECS` default/clamp **60**) |
| Workload / checksum | N/A — create never reaches exec |
| Host RAM during fail | Fine (~259 GiB used / ~1.4 TiB) |
| CPU guarantee math | Fine (0.125 × 710 ≈ 89 of ~352 cores) |

This is **not** guest OOM, agent flake, or image pull failure.

---

## Evidence (max-pack probe, 2026-08-26)

File: `data/agent/rlp-vera-c0p125-max1/concurrency_20260826_165634_n50.jsonl`  
Log: `/tmp/vera-agent-maxpack-n50.log` (run cancelled mid–c=1760)

Identity: each create timeout → **1** failed run row; each live sandbox → **8** episode rows (`-E 8`).

| Requested c | Failures | Live `c − fails` | Runs (eps + fails) |
|------------:|---------:|-----------------:|-------------------:|
| 880 | 170 | **710** | 5850 |
| 1056 | 347 | **709** | 6019 |
| 1408 | 699 | **709** | 6371 |

Pattern: **`fails(c) ≈ c − 710`**. Raising concurrency does not raise live VMs; it only times out the surplus.

Prior clean ladder (same flags) through **704 / 0 fails**:  
`data/agent/rlp-vera-c0p125-max1/concurrency_20260826_005637_n50.jsonl`

---

## Likely binding knobs (runner)

From RLP runner docs / `runner` env:

| Env | Role |
|-----|------|
| **`RLP_MAX_LIVE_VMS`** | LiveCount admission cap (default `2 × RLP_VM_CONCURRENCY`) — **prime suspect** if set near 704–720 |
| **`RLP_VM_CONCURRENCY`** | Create consumer / `vmSem` capacity |
| **`RLP_VM_PULL_WINDOW`** | JetStream pull window for creates |
| `RLP_RESERVE_PCT` | Headroom vs host CPU/mem ledger (less likely here — RAM/CPU headroom was large) |
| `RLP_CREATE_MAX_QUEUE_SECS` | Queue wait before fail (**clamped ~60s** — lengthening client timeouts will **not** bypass this) |

**First debug step on the Vera runner process:** print `RLP_MAX_LIVE_VMS`, `RLP_VM_CONCURRENCY`, `RLP_VM_PULL_WINDOW`, `RLP_RESERVE_PCT`.

Client-side `RLP_HTTP_MAX_CONNECTIONS` (harness default 512) is **not** the explanation for a flat 710 live count.

---

## What we already ruled out

- Dedicated 1-vCPU Class B (~348) — we use burst `0.125` + omit dedicated  
- Host memory exhaustion at 880–1408  
- Fractional CPU oversubscription math (~2816 theoretical at 0.125)  
- Agent checksum / pytest flake (those are `exit_code=0` with bad digest; these are create `-1`)

---

## How to test a fix

On the Vera node (`daytona@ipp8-d15-c2-vera-2`), after raising live/create caps:

```bash
cd ~/arm64-benchmark-1
UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target vera \
  --snapshot dtgraviet/vera-agent-benchmark:v3 \
  --levels 704 880 1056 1408 \
  --n 50 --seed 42 -E 8 --hold-then-exec \
  --rlp-cpu 0.125 --rlp-cpu-max 1
```

**Pass criteria**

| Level | Expect |
|-------|--------|
| 704 | `failures: 0`, `runs == 5632` (704×8) |
| 880 | `failures: 0`, `runs == 7040` — **must** clear the old cliff |
| 1056 / 1408 | `failures ≈ 0`, `runs ≈ c×8` (or document the new live ceiling if still capped) |

Quick check from a summary line: `live ≈ runs/8` when fails are create-shaped, or `failures == 0` and `runs == concurrency * 8`.

Optional stretch after 1408 is green: `--levels 1760 2112 2464 2784` (2784 ≈ 352/0.125).

---

## Do / don’t for eng agents

**Do**
- Treat this as **runner admission / max live VMs**, not a Vera silicon bug  
- Raise `RLP_MAX_LIVE_VMS` (and create concurrency/pull window) then re-probe 880+  
- Keep client on-node; same image/flags as above  

**Don’t**
- “Fix” by lowering benchmark concurrency only (hides the product limit)  
- Spend time on client create timeout >60s as the primary fix  
- Confuse this with the dedicated `--rlp-cpu 1` ~348 Class B ceiling  

---

## Contacts / artifacts

- Partial fail ladder JSONL: `…/concurrency_20260826_165634_n50.jsonl`  
- Clean through-704 JSONL: `…/concurrency_20260826_005637_n50.jsonl`  
- Workload: `workload/coding_loop.py`, `workload/agent.py`  
- Create path: `harness/rlp_create.py` (`omit_dedicated` when `--rlp-cpu-max` set)
