# Vera vs Zen 5 (Phoenix) — launch insights

Compare is **RLP 1 vCPU Firecracker vs RLP 1 vCPU Firecracker**: `rlp-vera` vs `rlp-phoenix` (AMD EPYC Zen 5 Turin, `us-phoenix-1`). Docker-on-node and `c0p125` are out of this document.

Numbers below are from complete ladders in `data/`, pinned by path. Do not re-run `eda.py` and trust “newest file” — that picker will crown a `c=1` smoke or a failed 352 wave.

NVIDIA-facing copy is [`final.md`](final.md). Do not paste pool size, warm pool, or `--hold-then-exec` into that brief. There: SSH local tunnel had a cap; we reran on the Vera node.

## Quote hygiene

| Metric | What it is | When to quote |
| --- | --- | --- |
| `duration_ms` | In-container chip time | Idle and packing **chip** claims |
| `latency_ms` | Wall time including create / toolbox | Only if you say it includes sandbox overhead |
| Throughput | Episodes / wave wall | Never at `c=1`. Vera on-node files use exec-wall (`hold_then_exec`). Phoenix files still include create from a laptop. Do not treat the two jobs/s lines as silicon. Do not quote Aug 19–21 tput at c≥88 as chip. |

Rules:

- Quote **0-fail**, same `-E`, same `--n` waves only. Omit **352** (fails on both chips in the pinned files).
- Do not mix `-E 1` with `-E 8`, or evals `--n 3` with `--n 1`.
- Phoenix `env.cpu_count=16` on older RL / analytics / disk / evals files is a topology leak, not 16 vCPUs. Later agent files correctly show `cpu_count=1`.
- Idle throughput (`c=1`, ~0.3/s) is create-dominated. Do not quote it as chip speed.
- `%` below is Vera better: lower duration/latency, higher throughput.
- Levels in the brief: **1, 8, 22, 44, 88, 132, 176**.

## What “degradation after 88” actually was (2026-08-21)

Engineering falsified the socket-fill hypothesis (Linux already spreads Firecracker
vCPU threads across both sockets; a fixed in-guest spin is flat through **132**
busy guests). Early laptop+SSH-tunnel Vera ladders showed jobs/s flattening
~51 → 53/s while in-guest p50 stayed ~900 ms. That plateau was the **SSH
local tunnel cap**, not host saturation.

Same 176-sandbox held fleet, guest p50 identical (~1.15 s) in every row:

| client | pool | exec tput | wall p50 |
| --- | ---: | ---: | ---: |
| laptop + SSH tunnel | 100 | 19.5/s | 7.6 s |
| laptop + SSH tunnel | 600 | 30.6/s | 6.6 s (tunnel TCP serializes) |
| rlp-control, 19 ms | 100 | 82.3/s | 1.9 s |
| rlp-control, 19 ms | 600 | 128.9/s | 1.2 s |

Confirmation ladders were then run **on the Vera node**
(`client_host=ipp8-d15-c2-vera-2`) with `--hold-then-exec`. Pinned Vera RL
(`…154514…`): p50 duration **882 ms at 88**, **994 ms at 132**, **1357 ms at
176**; exec-wall tput **84/s → 100/s → 89/s**. Zero fails through 176.

Phoenix in this compare is still laptop → **one runner** (cell DB: every create on `oc5002`; 192 physical cores). It is **not** a multi-host spread. New Phoenix RL duration stays ~0.60–0.69 s through labeled 176 because that wave was **under-driven** (laptop RTT/pool), so guests never saw ~176-way contention — and 176 < 192 cores, so the box still had headroom. **Do not reuse the old 3.7 s Phoenix-176 number.** **Do not explain the 0.69 s with “many EPYC hosts.”**

Vera at labeled 176 **was** ~176 concurrent episodes on a 176-core box (client on the node). Mean duration 1.48 s there is expected full-box behavior (SMT + FC housekeeping; spin p50 flat at 132, tail at 176), not evidence against the chip.

**C=1 `duration_ms` is the fair chip compare.** High-c duration on Phoenix is not.

The idle RL gap (0.89 s vs 0.60 s) is **arithmetic intensity**, not missing vector units. The big kernel `(8×384)@(384×384)` is ~1.18 MB float64 weights for 2.36 MFLOP (~2 FLOP/byte) — eight GEMVs, L2-bound. Clock × per-core cache bandwidth (Zen 5 boost) dominates. A perfect SVE2 OpenBLAS likely closes only part of the 1.5×. float32 or batch-64 would be the ISA-fit test.

---

## 1. Agent idle chip (~10% faster)

**Pin (on-node Vera hold-then-exec vs laptop Phoenix, 0-fail through 176):**

- Vera: `data/agent/rlp-vera/concurrency_20260821_161503_n200.jsonl` (`-E 8`, `--n 200`, `rlp_cpu=1`, `hold_then_exec=True`, `client_host=ipp8-d15-c2-vera-2`)
- Phoenix: `data/agent/rlp-phoenix/concurrency_20260821_164629_n200.jsonl` (`-E 8`, `--n 200`, `rlp_cpu=1`, laptop)

Do **not** use Phoenix `…164048…` (1 fail at 132).

| conc | Vera mean dur | Phoenix mean dur | dur | Vera tput | Phoenix tput | fails |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 2.518 s | 2.811 s | **+10.4%** | 0.36/s | 0.30/s | 0 / 0 |
| 8 | 2.558 s | 2.836 s | **+9.8%** | 2.83/s | 2.43/s | 0 / 0 |
| 22 | 2.611 s | 2.753 s | **+5.2%** | 7.63/s | 6.71/s | 0 / 0 |
| 44 | 2.697 s | 2.852 s | **+5.4%** | 14.53/s | 11.79/s | 0 / 0 |
| 88 | 2.853 s | 2.970 s | **+4.0%** | 26.53/s | 20.29/s | 0 / 0 |
| 132 | 3.186 s | 3.184 s | ~0% | 33.46/s | 28.64/s | 0 / 0 |
| 176 | 3.531 s | 3.527 s | ~0% | 41.20/s | 34.11/s | 0 / 0 |

Vera p50 duration at 176 is still shorter (**3.27 s vs 3.55 s**) even though means meet. Both sides 0-fail through 176. 352 in these files has fails (174 / 129) — omit.

Idle also holds on older `-E 1` ladders (~11% duration):

- Vera: `data/agent/rlp-vera/concurrency_20260821_003107_n200.jsonl`
- Phoenix: `data/agent/rlp-phoenix/concurrency_20260821_002917_n200.jsonl`
- `c=1`: 3.097 s vs 3.490 s

**Safe launch line:** Vera agent chip is ~10% faster at idle and stays ahead through 88 sandboxes. At 176 the mean times meet; Vera’s median is still shorter. Do not treat jobs/s as a matched packing bake-off (on-node held fleet vs laptop create).

---

## 2. Disk I/O — chip through 176

**Pin:**

- Vera: `data/disk/rlp-vera/concurrency_20260821_162121_n128.jsonl` (`-E 1`, `--n 128`, hold-then-exec, on-node)
- Phoenix: `data/disk/rlp-phoenix/concurrency_20260821_165436_n128.jsonl` (`-E 1`, `--n 128`, laptop)

Do **not** use Vera `data/disk/rlp-vera/concurrency_20260819_202058_n128.jsonl` — every wave failed. Do **not** quote Phoenix jobs/s at 44 (0.69/s stall). Omit 352 (14 / 25 fails).

| conc | Vera mean dur | Phoenix mean dur | dur | Vera tput | Phoenix tput | fails |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0.422 s | 0.532 s | **+20.7%** | 2.23/s | 0.50/s | 0 / 0 |
| 8 | 0.432 s | 0.526 s | **+18.0%** | 17.10/s | 4.05/s | 0 / 0 |
| 22 | 0.435 s | 0.536 s | **+18.9%** | 46.05/s | 7.75/s | 0 / 0 |
| 44 | 0.442 s | 0.574 s | **+23.0%** | 87.74/s | — | 0 / 0 |
| 88 | 0.457 s | 0.652 s | **+29.9%** | 155.75/s | 12.65/s | 0 / 0 |
| 132 | 0.480 s | 0.655 s | **+26.7%** | 185.82/s | 12.99/s | 0 / 0 |
| 176 | 0.521 s | 0.649 s | **+19.7%** | 228.04/s | 11.62/s | 0 / 0 |

Vera tput here is exec-wall on a held fleet (one job per sandbox, so exec wall is tiny). Phoenix tput includes create from a laptop. **Quote duration**, not 228 vs 12 as silicon.

**Safe launch line:** Vera local-disk work is ~18–30% faster than Zen 5 at every concurrency we measured through 176. Idle is ~21% (0.42 s vs 0.53 s).

---

## 3. Analytics — chip through 176

**Pin:**

- Vera: `data/analytics/rlp-vera/concurrency_20260821_162249_n200.jsonl` (`-E 8`, `--n 200`, hold-then-exec, on-node)
- Phoenix: `data/analytics/rlp-phoenix/concurrency_20260821_171146_n200.jsonl` (`-E 8`, `--n 200`, laptop)

Do **not** use Phoenix `…165956…` (536 fails at 352; superseded) or `…201837…` (1 fail at 88). Omit 352 (192 / 156 fails).

| conc | Vera mean dur | Phoenix mean dur | dur | Vera tput | Phoenix tput | fails |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 3.413 s | 4.203 s | **+18.8%** | 0.28/s | 0.22/s | 0 / 0 |
| 8 | 3.549 s | 4.271 s | **+16.9%** | 2.12/s | 1.64/s | 0 / 0 |
| 22 | 3.648 s | 4.393 s | **+17.0%** | 5.71/s | 3.87/s | 0 / 0 |
| 44 | 3.742 s | 4.435 s | **+15.6%** | 10.98/s | 7.75/s | 0 / 0 |
| 88 | 3.870 s | 4.531 s | **+14.6%** | 20.52/s | 15.26/s | 0 / 0 |
| 132 | 4.181 s | 4.788 s | **+12.7%** | 27.40/s | 21.26/s | 0 / 0 |
| 176 | 4.592 s | 5.434 s | **+15.5%** | 32.06/s | 23.19/s | 0 / 0 |

**Safe launch line:** Vera DuckDB/Parquet work is ~19% faster at idle and still faster at 176 sandboxes (4.59 s vs 5.43 s). Jobs/s is not a matched packing compare.

---

## 4. RL — idle chip is Phoenix; Vera jobs/s scales on-node

**Pin:**

- Vera: `data/rl/rlp-vera/concurrency_20260821_154514_n5000.jsonl` (`-E 8`, `--n 5000`, hold-then-exec, on-node)
- Phoenix: `data/rl/rlp-phoenix/concurrency_20260821_163715_n5000.jsonl` (`-E 8`, `--n 5000`, laptop, native snap `vera-rl-benchmark-us-phoenix-1`)

Do **not** use Phoenix `…163553…` (ARM Hub image, no amd64, all-fail). Do **not** use Phoenix `…195139…` for packing (old 3.7 s at 176). Omit 352 (80 / 170 fails).

| conc | Vera mean dur | Phoenix mean dur | dur | Vera tput | Phoenix tput | fails |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0.887 s | 0.604 s | −47% | 1.05/s | 1.09/s | 0 / 0 |
| 8 | 0.877 s | 0.592 s | −48% | 8.34/s | 8.51/s | 0 / 0 |
| 22 | 0.888 s | 0.593 s | −50% | 20.69/s | 20.81/s | 0 / 0 |
| 44 | 0.883 s | 0.600 s | −47% | 41.77/s | 34.76/s | 0 / 0 |
| 88 | 0.885 s | 0.610 s | −45% | **83.66/s** | 58.75/s | 0 / 0 |
| 132 | 1.049 s | 0.649 s | −62% | **99.76/s** | 79.47/s | 0 / 0 |
| 176 | 1.478 s | 0.685 s | −116% | 88.89/s | 89.43/s | 0 / 0 |

Vera p50 duration: 882 ms at 88, 994 ms at 132, 1357 ms at 176. The 176 stretch is a fully driven 176/176-core box (plus client on that node). Phoenix 0.69 s at labeled 176 is laptop under-drive on a 192-core single runner, not a packing win and not multi-host placement.

Idle 1.5× (0.89 vs 0.60) is cache-bandwidth / clock, not SVE. See arithmetic-intensity note above.

**Safe launch line:** One sandbox is the chip compare: this sequential float64 loop is currently faster on Zen 5. That is GEMV/cache intensity, not “Vera lacks vector units.” After leaving the SSH tunnel, Vera’s jobs/s scales to ~84/s at 88 and ~100/s at 132. Do not quote 1.48 s vs 0.69 s at 176 as silicon. Do not say Vera keeps ~1 s while Zen 5 slows to 3.7 s.

---

## Do not say

- **“At 176, Vera 1.48 s vs Zen 5 0.69 s is a packing/chip loss.”** Vera was fully driven at 176/176 cores. Phoenix was laptop-throttled on one 192-core runner (`oc5002`). C=1 is the chip compare.
- **“Phoenix 176 landed across many EPYC hosts.”** False. One-runner region; all creates on `oc5002`.
- **“SVE kernels will close the 1.5× idle RL gap.”** Unlikely to close all of it; the kernel is ~2 FLOP/byte GEMV / L2-bound.
- **“Vera beats Zen 5 on agent packing duration at 176.”** Means meet (~3.53 s). Vera p50 is still shorter (3.27 vs 3.55). Lead is through 88.
- **“Packing dies at 88 because Vera fills one socket.”** Falsified. Tunnel cap; in-guest time flat through 88; core sharing near 176.
- **August 19–21 jobs/s at c≥88 as chip packing.** Tunnel-capped.
- **Mismatched jobs/s as silicon** (228 disk/s vs 12, etc.). Vera exec-wall on-node vs Phoenix laptop create.
- **Any 352 row.** Fails on both chips in the pinned files.
- **Phoenix RL `…163553…`.** ARM-only Hub image.
- **Phoenix agent `…164048…`.** 1 fail at 132.
- **Phoenix analytics `…165956…`.** Superseded; 536 fails at 352.
- **“Vera wins evals.”** Matched `-E 8 --n 1`: Phoenix idle ~1.32 s vs Vera ~1.49 s. Files: `data/evals/rlp-vera/concurrency_20260820_184801_n1.jsonl` vs `data/evals/rlp-phoenix/concurrency_20260820_202442_n1.jsonl`. Not in `final.md`.
- **Evals `n=3` vs `n=1`.** Fake gap.
- **“Vera wins media / FFmpeg.”** Phoenix idle ~8.6 s vs Vera ~15.3 s. Vera 176 has **52 fails**.
- **Idle RL chip as a Vera win.** Phoenix ~0.60 s vs Vera ~0.89 s.
- **Idle (`c=1`) throughput as chip speed.**
- **Disk `…202058…`.** All-fail garbage.
- **Phoenix disk jobs/s at 44.** 0.69/s stall.
- **0.125 CPU density** and **Docker-on-node 88 vs RLP 88.** Different product.
- **Phoenix `cpu_count=16` means 16 vCPUs.** Topology leak.

---

## Brief charts

Pinned in `scripts/nvidia_brief_charts.py`. Regenerate with:

```bash
uv run python scripts/nvidia_brief_charts.py
```

Output: `eda_output/nvidia-brief/`.
