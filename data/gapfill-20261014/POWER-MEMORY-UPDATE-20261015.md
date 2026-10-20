# Power and memory update: verified results behind report v3

## Headline

The memory-streaming test reveals a large Vera advantage that the CPU-bound agent benchmark did not exercise:
approximately **2.1 TB/s across the dual-socket Vera host**, versus **0.60 TB/s on Graviton5** and **0.305 TB/s on the
single-socket EPYC 9575F**. These are whole-host effective triad rates, not measured DRAM-controller traffic or
per-chip speedups. Turin's memory test remains pending; the power data for Turin is available.

## What was independently checked

`audit-power-memory.py` reads the three preserved archives without extracting or modifying them. Its output,
`power-memory-audit-20261015.json`, records their SHA-256 hashes, exact run selection, per-run counts, timing bounds,
and power-domain means.

- Identical `memtest.c` SHA-256 across all three completed hosts.
- Every successful record uses 2^24 elements per array: three arrays total 384 MiB.
- Every output checksum matches the triad's expected result for its pass count.
- Every bandwidth value matches `passes × 3 × elements × 8 / duration`, within output-rounding tolerance.
- Every reported aggregate equals the sum of successful sandbox rates; requested/success/failure counts reconcile.
- Accepted memory runs use `buildpack-deps:bookworm` rather than the failing `gcc:14` image.
- Host-side RPC timing, combined with each kernel's monotonic duration, gives a conservative common-overlap lower
  bound of 29.08 s on Vera, 29.45 s on Graviton5 and 28.53 s on the 9575F for approximately 30-second kernels.
  This avoids the invalid assumption that restored Arm guest wall clocks match the host clock.
- The new agent/power ladders completed 26,208 jobs each on Vera and the 9575F with zero failures and valid checksums.

## Corrections and qualifications

1. **Vera's AP meter is not equivalent to AMD package power.** The separate meter study is consistent with AP including
   LPDDR, regulator losses and additional rails. Earlier instructions that both meters excluded memory were incorrect.
   NVIDIA's public Grace documentation explains similar boundary differences but is not a Vera sensor specification.
2. **No whole-system efficiency ranking is established.** Only the 9575F has a usable wall-power result in the long
   agent run. Vera Total is a socket-module meter, not wall power. Turin has package power only; AWS exposes none here.
3. **The memory failure denominator is 2,034, not approximately 1,042.** Vera had 7 setup failures across the 16 measured
   repetitions. Both nominal 128-sandbox peak repetitions actually ran 127. A fully successful 256-sandbox repetition
   still delivered 2.07 TB/s. The 9575F completed 466/466 requests; Graviton5 818/818.
4. **The new clean agent runs do not erase earlier failures.** The previous 2,000-sandbox tests had one failed job per
   host; the new power runs had none. Report both observations rather than an inherent reliability ranking.
5. **Clock figures have changed with the measurement method.** Common busy-core sampling gives Vera 3.39 → 3.37 GHz
   and the 9575F 4.33 → 3.65–3.69 GHz, approximately −0.6% and −15%. The older −6% / −24% figures do not describe these
   runs. Turin and Graviton5 still use different methods.
6. **The single-job figure is no longer just historical.** The current Vera build measured 5.922 s at c=44; the 9575F
   measured 6.709 s. The earlier report's caveat that these numbers only came from September is superseded.
7. **The power windows are approximate.** The kit infers execution intervals from sampled summary arrival and
   `exec_wall_s`; deletion and sampling delay can shift boundaries. Use the long plateau averages as approximate
   readings, not precise per-job joule accounting. Short memory-run BMC readings are too sparse and lagged.

## Quantities that can be quoted, with scope

| Measurement | HQ Vera | Graviton5 | EPYC 9575F | Turin |
|---|---:|---:|---:|---:|
| Memory-streaming host plateau | about 2.1 TB/s | about 0.60 TB/s | about 0.305 TB/s | pending |
| Single-sandbox mean of two reps | 72.26 GB/s | 57.45 GB/s | 46.105 GB/s | pending |
| Agent jobs/s at 2,000 (latest available runs) | 26.25 | 23.38 | 8.02 | 22.15 |
| J/job at 2,000, explicitly different power scopes | 42.3, AP | unavailable | 47.7, CPU package | 44.1, two CPU packages |

The broad Vera AP measurement gives encouraging energy-per-job results despite covering more components, but no
apples-to-apples efficiency percentage is justified. The CPU-output-plus-SoC estimate is diagnostic, not a validated
equivalent AMD package domain.

## Publication framing

Supported: **Vera provides strong agent-workload throughput and substantially higher memory-streaming throughput
inside sandboxes than the completed Graviton5 and 9575F configurations.**

Not established: 3.5–7× faster end-to-end agents, an equivalent advantage over Turin, faster sandbox startup, an
uninterrupted-operation guarantee, or a whole-server energy-efficiency percentage.

## Sources

- `../vera-hq-cell-20261014/power-mem-20261015/RESULTS.md`, `vera-power-mem.tgz`, `epyc9575-power-mem.tgz`,
  `SSDT6.dsl`, `SSDT7.dsl`, `mem-power.py`, `vera-meter-an.py`.
- `../graviton5-cell-20261014/FINDINGS.md` section 8 and `mem-ladder-20261015.tgz`.
- `../phoenix-e6-cell-20261014/FINDINGS.md` power section and `power-mem/` samples.
- [NVIDIA Grace tuning guide: Power Telemetry](https://docs.nvidia.com/grace-perf-tuning-guide/power-thermals.html#power-telemetry),
  used as architecture-specific background rather than Vera meter proof.
