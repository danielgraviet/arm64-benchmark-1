# Eng ticket: Redswitches max-pack create failures above c=880

**Audience:** eng / RLP agents debugging create capacity on the **redswitches** cell  
**Date:** 2026-08-28  
**Cell:** `redswitches` · API `https://api.redswitches.rlp.trydaytona.com`  
**Hardware:** AMD EPYC Turin **9575F** (Zen 5, 64C/128T)  
**Reporter:** Daniel Graviet (`arm64-benchmark-1`)

---

## One-line ask

Agent max-pack ladder is **clean through concurrency 880**, then mass **create timeouts** at **1056+**. Live sandboxes plateau around **~512–513** regardless of requested concurrency. Please find and raise the binding **live-VM / create-admission** (or memory ledger) cap so we can finish the Vera-matched m512 ladder.

---

## What we are measuring

| Item | Value |
|------|--------|
| Repo | `arm64-benchmark-1` |
| Benchmark | `agent` / `repo-agent-v3` |
| Image | `dtgraviet/vera-agent-benchmark:v3` |
| Recipe | `--n 50 --seed 42 -E 8 --hold-then-exec --rlp-cpu 0.125 --rlp-cpu-max 1 --rlp-memory 0.5` |
| Target | `--target redswitches` |
| Client | Laptop (`Daniels-MacBook-Air-5.local`) — **re-verify on-node after fix** |
| Series dir | `data/agent/rlp-redswitches-c0p125-max1-m512/` |

`--rlp-memory 0.5` (512 MiB) is **required** on redswitches to avoid the mem:cpu ratio floor.  
`--rlp-cpu-max 1` omits dedicated mode (burstable fractional CPU), same as Vera/Phoenix max-pack runs.

**Related clean run (base 1 GiB, through c=704):**  
`data/agent/rlp-redswitches-c0p125-max1/concurrency_20260828_183551_n50.jsonl` — **0 failures** on all 11 levels.

---

## Error you will see

```text
DaytonaError: Sandbox <id>-redswitches failed to start
(state=error, reason=create job not picked up by any runner within 60s
 (no matching capacity))
```

| Field | Observed |
|-------|----------|
| Client `exit_code` | **-1** |
| Timing | ~60–88 s (create queue timeout) |
| Workload / checksum | N/A — sandbox never reaches exec |
| Failure shape | **1 failed row per timed-out create** (not 8 episode rows) |

Same error class as the Vera live-VM wall ticket: `tickets/eng-vera-live-vm-wall.md`.

---

## Evidence (max-pack probe, 2026-08-28)

**File:** `data/agent/rlp-redswitches-c0p125-max1-m512/concurrency_20260828_194955_n50.jsonl`  
**Log:** `/tmp/redswitches-agent-maxpack.log`  
**Status:** Run **cancelled** by operator after c=1408 (1760 never started)

Identity: each create timeout → **1** failed run row; each live sandbox → **8** episode rows (`-E 8`).

| Requested c | Failures | Live `c − fails` | Runs (eps + fails) | checksum_ok |
|------------:|---------:|-----------------:|-------------------:|:-----------:|
| 704 | 0 | **704** | 5632 | yes |
| 880 | 0 | **880** | 7040 | yes |
| 1056 | 543 | **513** | 4647 | no |
| 1408 | 896 | **512** | 4992 | no |

Pattern at 1056+: **`fails(c) ≈ c − 512`**. Raising concurrency does not raise live VMs; surplus creates time out.

Note: **880 is fully clean** — the cliff is between 880 and 1056, not at the base 704 ladder.

---

## Likely binding knobs (runner)

Same suspects as Vera / Phoenix max-pack debugging:

| Env | Role |
|-----|------|
| **`RLP_MAX_LIVE_VMS`** | LiveCount admission cap — **prime suspect** if set near 512–720 |
| **`RLP_VM_CONCURRENCY`** | Create consumer / `vmSem` capacity |
| **`RLP_VM_PULL_WINDOW`** | JetStream pull window for creates |
| **`RLP_RESERVE_PCT`** | Headroom vs host CPU/mem ledger |
| `RLP_CREATE_MAX_QUEUE_SECS` | Queue wait before fail (~60s clamp) |

Also worth checking on this **smaller cell**:

- **Memory ledger** at 512 MiB × N sandboxes (880 × 0.5 GiB guest RAM is already ~440 GiB reserved on paper)
- Whether **512 live VMs** correlates with **64 physical cores × 0.125 vCPU guarantee** (512 × 0.125 = 64)
- Leftover sandboxes from aborted waves (paginated API list; cleanup before re-probe)

**First debug step on the redswitches runner:** print `RLP_MAX_LIVE_VMS`, `RLP_VM_CONCURRENCY`, `RLP_VM_PULL_WINDOW`, `RLP_RESERVE_PCT`, and current live VM count during a failing wave.

---

## What we already ruled out

- Agent workload flake / bad checksum (failures are create `-1`, not exec errors)
- Base ladder through **704** at 1 GiB (0 failures — cell and image are healthy at moderate density)
- Dedicated 1-vCPU mode (we use burst `0.125` + omit dedicated via `--rlp-cpu-max 1`)

**Not yet ruled out:** laptop client vs on-node API path. After raising caps, re-run from the **cell host** (same pattern as Vera/Phoenix in `RUNBOOK.md`).

---

## How to reproduce

From a machine with redswitches API access (`RS_KEY` / `REDSWITCHES_RLP_API_KEY`):

```bash
cd arm64-benchmark-1

UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target redswitches \
  --snapshot dtgraviet/vera-agent-benchmark:v3 \
  --levels 704 880 1056 1408 \
  --n 50 --seed 42 -E 8 --hold-then-exec \
  --rlp-cpu 0.125 --rlp-cpu-max 1 --rlp-memory 0.5
```

Full Vera-matched ladder (after 1408 is green):

```bash
--levels 704 880 1056 1408 1760 2112 2464 2784
```

**Pass criteria**

| Level | Expect |
|-------|--------|
| 704 | `failures: 0`, `runs == 5632` |
| 880 | `failures: 0`, `runs == 7040` |
| 1056 | `failures: 0`, `runs == 8448` — **must clear the ~512 live cliff** |
| 1408 | `failures ≈ 0`, `runs == 11264` |

Quick check: `live ≈ runs/8` when failures are create-shaped, or `failures == 0` and `runs == concurrency × 8`.

---

## Do / don’t

**Do**
- Treat as **runner admission / capacity**, not a Zen 5 silicon bug
- Compare runner env against Vera/Phoenix cells that completed 880+ cleanly
- Re-probe from **on-node** client after fix

**Don’t**
- Use the partial c=1056 / c=1408 JSONL rows for headline charts (checksum not OK, heavy create loss)
- “Fix” by lowering benchmark concurrency only
- Assume laptop remote API is equivalent to on-node without verification

---

## Artifacts

| Artifact | Path |
|----------|------|
| Partial max-pack JSONL | `data/agent/rlp-redswitches-c0p125-max1-m512/concurrency_20260828_194955_n50.jsonl` |
| Clean base ladder (704) | `data/agent/rlp-redswitches-c0p125-max1/concurrency_20260828_183551_n50.jsonl` |
| Run log | `/tmp/redswitches-agent-maxpack.log` |
| Harness wiring | `harness/regions.py` (`redswitches` API + toolbox URLs) |
| Similar ticket (Vera ~710 wall) | `tickets/eng-vera-live-vm-wall.md` |
| Phoenix max-pack runbook | `tickets/phoenix-agent-maxpack-run.md` |
