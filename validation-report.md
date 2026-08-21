# Vera claim validation

## Verdict

The claim is directionally supported, provided the hardware explanation is
attributed to NVIDIA rather than presented as something this benchmark
measured directly.

Daytona’s RLP sandbox evaluation shows:

- About **10% faster repo-agent work** on one Vera vCPU, with Vera ahead through
  88 concurrent sandboxes. At 176, Zen 5 is faster ([final.md](final.md:35)).
- About **40% faster local-disk work** on one vCPU, remaining roughly 35–40%
  faster through 176 sandboxes ([final.md](final.md:59)).
- Stronger **SQL/Parquet analytics**: Vera is about 28% faster at one sandbox
  and remains faster at 176; at 88 it completes 18.3 versus 15.6 jobs/s
  ([final.md](final.md:83)).
- Strong high-concurrency stability for the NumPy workload: at 176 sandboxes,
  Vera stays near 1 second per rollout while Phoenix reaches about 3.7 seconds;
  Vera also completes 352 concurrent rollouts with zero failures
  ([final.md](final.md:107)).

The repo-agent, disk, and analytics jobs are Python workloads. The analytics
job generates Parquet data and runs DuckDB joins, filters, and aggregations;
the rollout job uses NumPy matrix multiplies and environment updates
([workload/agent.py](workload/agent.py:84), [analytics/pipeline.py](analytics/pipeline.py:1), [rl/policy.py](rl/policy.py:1)).

The Vera node inspection confirms the relevant ISA surface: NVIDIA/Olympus,
352 logical CPUs, 176 physical cores, `sve2`, and FP8-related flags including
`f8fma`, `f8dp4`, `f8e4m3`, and `f8e5m2`. `perf` also exposes FP8 operation
events and SVE instruction counters. This supports NVIDIA’s hardware
explanation for why memory-moving Python and SQL workloads may perform well.
It still does not provide a GB/s measurement or prove that these repository
workloads executed FP8 instructions.

## Recommended statement

> Daytona’s RLP sandbox evaluations show good gains for repo-agent workloads on NVIDIA Vera, with especially strong performance on local-disk and SQL/Parquet analytics workloads that move substantial data. Vera also maintains stable performance at high concurrency, including for NumPy-heavy Python rollouts.

## Quick Vera-node check

Run this on the SSH node:

```bash
uname -a
lscpu
grep -m1 -Ei 'features|flags' /proc/cpuinfo
command -v perf && perf list 2>/dev/null | grep -Ei 'sve|fp8|bandwidth|memory' | head -40
python - <<'PY'
import numpy as np
print('NumPy:', np.__version__)
np.__config__.show()
PY
```

For a direct bandwidth number, run an installed bandwidth benchmark such as:

```bash
command -v stream || command -v mbw
stream 2>/dev/null || mbw -n 5 1024
```

The supplied node output already confirms the CPU flags and `perf` events. A
GB/s claim still requires a bandwidth benchmark result; FP8 execution requires
running an FP8 workload while counting the FP8 events, for example:

```bash
perf stat -a -e fp_fp8_fixed_min_ops_spec,fp_fp8_scale_min_ops_spec \
  <your-fp8-benchmark-command>
```

Record the benchmark version, thread count, buffer size, and result before
using a GB/s claim. The current repository workloads remain valid as Python,
NumPy, disk, and SQL/Parquet performance evidence, but are not FP8 probes.

The Vera node’s `mbw -n 5 1024` probe reported **24,881 MiB/s average
`MEMCPY`** (about **26.1 GB/s**), **47,612 MiB/s `DUMB`**, and **99,021 MiB/s
`MCBLOCK`**. These are measured memory-movement results, but `mbw` is a simple
copy benchmark; this output alone does not establish peak socket bandwidth or
a 2× advantage. Run the identical command with the same buffer size, method,
and CPU/NUMA placement on Phoenix before making that comparison.

The NUMA-pinned rerun was consistent: `MEMCPY` averaged **24,765 MiB/s**,
versus 24,881 MiB/s unpinned (about a **0.5%** difference). That supports the
stability of the Vera measurement on NUMA node 0.
