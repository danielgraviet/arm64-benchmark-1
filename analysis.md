# Vera vs Zen 5 (Phoenix) — launch insights

Compare is **RLP 1 vCPU Firecracker vs RLP 1 vCPU Firecracker**: `rlp-vera` vs `rlp-phoenix` (AMD EPYC Zen 5 Turin, `us-phoenix-1`). Docker-on-node and `c0p125` are out of this document.

Numbers below are from complete ladders in `data/`, pinned by path. Do not re-run `eda.py` and trust “newest file” — that picker will crown a `c=1` smoke (for example `data/agent/rlp-vera/concurrency_20260821_035940_n200.jsonl`).

## Quote hygiene

| Metric | What it is | When to quote |
| --- | --- | --- |
| `duration_ms` | In-container chip time | Idle and packing **chip** claims |
| `latency_ms` | Wall time including create / toolbox | Only if you say it includes sandbox overhead |
| Throughput | Episodes / wave wall (creates + client) | Packing / density **only** from colo + `--hold-then-exec` (use `exec_wall_s`). Never at `c=1`. Do not quote Aug 19–21 tput at c≥88 as chip. |

Rules:

- Quote **0-fail**, same `-E`, same `--n` waves only.
- Do not mix `-E 1` with `-E 8`, or evals `--n 3` with `--n 1`.
- Phoenix `env.cpu_count=16` on older RL / analytics / disk / evals files is a topology leak, not 16 vCPUs. Later agent files correctly show `cpu_count=1`.
- Idle throughput (`c=1`, ~0.3/s) is create-dominated. Do not quote it as chip speed.
- `%` below is Vera better: lower duration/latency, higher throughput.

## What “degradation after 88” actually was (2026-08-21)

Engineering falsified the socket-fill hypothesis (Linux already spreads Firecracker
vCPU threads across both sockets; a fixed in-guest spin is flat through **132**
busy guests). On the pinned Vera RL ladder, **p50 `duration_ms` barely moves**
(875 → 940 ms through c=176). What rises is **p99** and the slow-episode rate
(0.6% → 6.5%), and **jobs/s flatten 51 → 53/s** while in-guest p50 stays ~900 ms.

That plateau is **not host saturation**. Same 176-sandbox held fleet, guest p50
identical (~1.15 s) in every row:

| client | pool | exec tput | wall p50 |
| --- | ---: | ---: | ---: |
| laptop + SSH tunnel | 100 | 19.5/s | 7.6 s |
| laptop + SSH tunnel | 600 | 30.6/s | 6.6 s (tunnel TCP serializes) |
| rlp-control, 19 ms | 100 | 82.3/s | 1.9 s |
| rlp-control, 19 ms | 600 | 128.9/s | 1.2 s |

The c≥88 p99 tail is **create/delete churn** (boot storms, loadavg 200–400)
interleaving with running episodes because the 100-conn pool staggers creates.
Real core contention on this box starts at **~176 physical cores**, tail-first.

**Quote `duration_ms` (p50) as chip.** Do not quote August 19–21 `latency_ms` or
jobs/s at c≥88 as silicon. Historical tput/latency are not comparable to a
colo + pool 512 + `--hold-then-exec` ladder without noting client config.

Harness: `harness/rlp_client_tuning.py` (from `origin/concurrency-fix`) auto-widens
the SDK pool 100→512 and tempers `wait_until_started` polls. `--hold-then-exec`
pre-creates the fleet, then execs. Run Vera from **rlp-control** (LAN
`http://10.96.8.181:8088`, not laptop localhost). Commands:
`scripts/run_clean_ladders.sh`.

This laptop cannot resolve `rlp-control` and SSH to `daytona@10.96.8.181` is
publickey-denied, so the 176-wide confirmation ladders were not started here.
Pin new JSONL by path here when those files exist; do not invent a 176 jobs/s
number until they do.

---

## 1. Agent idle chip (~10% faster) — most stable number

Same-week `-E 8 --n 200` idle mean duration is **~2.53 s Vera vs ~2.81 s Phoenix** on every full ladder.

**Pin (latest 0-fail pair):**

- Vera: `data/agent/rlp-vera/concurrency_20260821_030511_n200.jsonl` (`-E 8`, `--n 200`, `rlp_cpu=1`)
- Phoenix: `data/agent/rlp-phoenix/concurrency_20260821_030926_n200.jsonl` (`-E 8`, `--n 200`, `rlp_cpu=1`)

| conc | Vera mean dur | Phoenix mean dur | dur | Vera p50 lat | Phoenix p50 lat | lat | Vera tput | Phoenix tput | tput | fails |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 2.530 s | 2.821 s | **+10.3%** | 2655 ms | 2980 ms | **+10.9%** | 0.35/s | 0.30/s | (do not quote) | 0 / 0 |
| 8 | 2.554 s | 2.840 s | **+10.1%** | 2663 ms | 3018 ms | **+11.8%** | 2.77/s | 2.41/s | +14.9% | 0 / 0 |
| 22 | 2.600 s | 2.834 s | **+8.3%** | 2746 ms | 2995 ms | **+8.3%** | 7.43/s | 6.59/s | +12.7% | 0 / 0 |
| 44 | 2.662 s | 2.817 s | **+5.5%** | 2839 ms | 3074 ms | **+7.6%** | 12.79/s | 12.27/s | +4.2% | 0 / 0 |
| 88 | 2.801 s | 2.976 s | **+5.9%** | 3013 ms | 3234 ms | **+6.8%** | 24.00/s | 21.99/s | mixed — see below | 0 / 0 |
| 176 | 4.323 s | 3.574 s | −20.9% | 4983 ms | 3850 ms | −29.4% | 30.43/s | 36.40/s | **Phoenix** | 0 / 0 |

Idle also holds on `-E 1` ladders (~11% duration):

- Vera: `data/agent/rlp-vera/concurrency_20260821_003107_n200.jsonl`
- Phoenix: `data/agent/rlp-phoenix/concurrency_20260821_002917_n200.jsonl`
- `c=1`: 3.097 s vs 3.490 s

**Safe launch line:** Vera agent chip is ~10% faster at idle and stays ahead through 88 sandboxes. Do not pick a winner on 88 throughput (replicate noise). Do not send “Phoenix wins agent packing at 176” until a colo hold-then-exec rerun — that 4.32 s in-guest rise is still mixed with create/delete churn.

Agent 88 tput range across 0-fail `-E 8` full ladders: Vera **22.1–24.7/s**, Phoenix **22.0–23.7/s**. Latest pair Vera 24.0 vs 22.0; previous pair (`…025238…` vs `…024840…`) Phoenix 23.7 vs 22.4.

---

## 2. Disk I/O — largest clean chip + packing win

**Pin (only these files):**

- Vera: `data/disk/rlp-vera/concurrency_20260819_202521_n128.jsonl` (`-E 1`, `--n 128`)
- Phoenix: `data/disk/rlp-phoenix/concurrency_20260820_204117_n128.jsonl` (`-E 1`, `--n 128`)

Do **not** use Vera `data/disk/rlp-vera/concurrency_20260819_202058_n128.jsonl` — every wave failed (no `duration_ms`, garbage thousands/s throughput).

| conc | Vera mean dur | Phoenix mean dur | dur | Vera tput | Phoenix tput | tput | fails |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0.426 s | 0.713 s | **+40.3%** | 1.34/s | 0.82/s | **+63%** | 0 / 0 |
| 8 | 0.421 s | 0.664 s | **+36.6%** | 9.97/s | 5.79/s | **+72%** | 0 / 0 |
| 22 | 0.429 s | 0.662 s | **+35.2%** | 17.92/s | 12.01/s | **+49%** | 0 / 0 |
| 44 | 0.431 s | 0.667 s | **+35.4%** | 23.57/s | 19.01/s | **+24%** | 0 / 0 |
| 88 | 0.434 s | 0.681 s | **+36.2%** | 34.19/s | 26.38/s | **+30%** | 0 / 0 |
| 176 | 0.444 s | 0.677 s | **+34.4%** | 31.70/s | 22.09/s | **+44%** | 0 / 0 |
| 352 | 0.443 s | 0.688 s | +35.6% | 19.54/s | 15.79/s | — | 0 / **1** |

Phoenix `c=352` has 1 fail: duration is still Vera, but do not quote that throughput.

**Safe launch line:** Vera local-disk work is ~35–40% faster than Zen 5 at every concurrency we measured, with higher packing throughput through 176.

---

## 3. Analytics — chip through 176; throughput at 88

**Pin (0-fail Phoenix ladder):**

- Vera: `data/analytics/rlp-vera/concurrency_20260819_222014_n200.jsonl` (`-E 8`, `--n 200`)
- Phoenix: `data/analytics/rlp-phoenix/concurrency_20260820_201308_n200.jsonl` (`-E 8`, `--n 200`)

Do **not** use Phoenix `…201837…` for `c=88` (1 fail). That file’s idle duration is 3.80 s (still slower than Vera 3.39 s).

| conc | Vera mean dur | Phoenix mean dur | dur | Vera tput | Phoenix tput | tput | fails |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 3.391 s | 4.684 s | **+27.6%** | 0.28/s | 0.20/s | (do not quote) | 0 / 0 |
| 8 | 3.546 s | 4.568 s | **+22.4%** | 2.11/s | 1.53/s | +38% | 0 / 0 |
| 22 | 3.615 s | 3.923 s | **+7.9%** | 5.48/s | 4.72/s | +16% | 0 / 0 |
| 44 | 3.724 s | 4.044 s | **+7.9%** | 10.47/s | 8.88/s | +18% | 0 / 0 |
| 88 | 3.933 s | 4.424 s | **+11.1%** | 18.33/s | 15.56/s | **+18%** | 0 / 0 |
| 176 | 4.420 s | 5.082 s | **+13.0%** | 14.42/s | 14.01/s | **tie** | 0 / 0 |

**Safe launch line:** Vera DuckDB/Parquet work is faster at idle and still faster at 176 sandboxes. At 88 concurrent sandboxes Vera also moves more episodes per second (~18% ). At 176, throughput is a tie; chip time is not.

---

## 4. RL density — packing headline (idle chip is Phoenix)

**Pin:**

- Vera: `data/rl/rlp-vera/concurrency_20260819_190856_n5000.jsonl` (`-E 8`, `--n 5000`)
- Phoenix: `data/rl/rlp-phoenix/concurrency_20260820_195139_n5000.jsonl` (`-E 8`, `--n 5000`)

Sister Phoenix `…194150…` shows the same cliff (176: 2.52 s / 43.4/s, still Vera; 352: 55 fails, truncated).

| conc | Vera mean dur | Phoenix mean dur | dur | Vera tput | Phoenix tput | tput | fails |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0.884 s | 0.499 s | −77% | 0.98/s | 1.46/s | **Phoenix chip** | 0 / 0 |
| 8 | 0.874 s | 0.492 s | −77% | 7.77/s | 11.27/s | Phoenix | 0 / 0 |
| 22 | 0.872 s | 0.496 s | −76% | 20.07/s | 26.44/s | Phoenix | 0 / 0 |
| 44 | 0.880 s | 0.558 s | −58% | 35.48/s | 42.18/s | Phoenix | 0 / 0 |
| 88 | 0.900 s | 0.766 s | −17% | 51.23/s | 56.06/s | Phoenix | 0 / 0 |
| 176 | 0.976 s | 3.699 s | **+74%** | 53.12/s | 35.92/s | **+48%** | 0 / 0 |
| 352 | 0.965 s | ~11.7 s | directional | 63.89/s | 19.08/s | — | 0 / **31** |

Phoenix 352 is truncated (2599 / 2816 runs) and checksum-false. Quote 352 as **Vera stability** (0.97 s, 63.9/s, 0 fails, 2816 runs), not as a Phoenix throughput number.

**Safe launch line:** Zen 5 is faster on a single RL episode. At 176 concurrent 1 vCPU sandboxes Vera holds ~1 s episode time and higher throughput while Phoenix slows to ~3.7 s. Vera still runs 352 concurrent episodes with zero fails.

---

## Do not say

- **“Vera beats Zen 5 on agent packing at 176.”** Not until a colo hold-then-exec ladder. The Aug 21 in-guest rise is still mixed with churn.
- **“Packing dies at 88 because Vera fills one socket.”** Falsified: placement is dual-socket from the start; in-guest spin is flat through 132; the 88 plateau is client pool + tunnel + create storms.
- **August 19–21 jobs/s at c≥88 as chip packing.** Client-capped. Eng colo held-fleet: 82.3/s (pool 100) to 128.9/s (pool 600) with guest p50 unchanged.
- **“Vera wins agent throughput at 88.”** Replicate ranges overlap. Say competitive.
- **“Vera wins evals.”** Matched `-E 8 --n 1`: Phoenix idle ~1.32 s vs Vera ~1.49 s; 176 tput **44.5/s vs 30.1/s**. Files: `data/evals/rlp-vera/concurrency_20260820_184801_n1.jsonl` vs `data/evals/rlp-phoenix/concurrency_20260820_202442_n1.jsonl`.
- **Evals `n=3` vs `n=1`.** Vera `…205002…` (`--n 3`) vs Phoenix `…202442…` (`--n 1`) is a fake 5 s vs 1.3 s gap.
- **“Vera wins media / FFmpeg.”** Phoenix idle ~8.6 s vs Vera ~15.3 s. Vera 176 has **52 fails**. Files: `data/media/rlp-vera/concurrency_20260819_224229_n40.jsonl` vs `data/media/rlp-phoenix/concurrency_20260820_210230_n40.jsonl`.
- **Idle RL chip as a Vera win.** Phoenix 0.50 s vs Vera 0.88 s.
- **Idle (`c=1`) throughput as chip speed.** Create-dominated.
- **Disk `…202058…`.** All-fail garbage.
- **Phoenix analytics `…201837…` at 88.** 1 fail; use `…201308…`.
- **Phoenix agent `…200209…` at 176.** 1 fail; do not quote 31.6/s.
- **0.125 CPU density** and **Docker-on-node 88 vs RLP 88.** Different product (CFS packing vs isolated Firecracker VMs). Out of this compare.
- **Phoenix `cpu_count=16` means 16 vCPUs.** Topology leak.

---

## Optional confirmation runs (required before quoting high-c jobs/s)

August 18–21 duration_ms at idle is shippable. High-c jobs/s and the agent-176
duration cliff are **not** chip-clean until colo + `--hold-then-exec`. Skip evals,
media, 0.125, Docker, and agent 352.

After any new file, pin by path here; do not trust EDA “newest.”

```bash
# From rlp-control (Vera) / phoenix cell API host. See scripts/run_clean_ladders.sh
UV_NO_SYNC=1 uv run main.py --benchmark rl --runner rlp --target vera \
  --snapshot dtgraviet/vera-agent-benchmark-rl:latest \
  --levels 1 44 88 132 176 352 --n 5000 --seed 42 -E 8 --hold-then-exec
```
