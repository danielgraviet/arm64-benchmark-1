# Redswitches: 2000-concurrency max-pack ladder (2026-08-28)

Answers the ticket "Redswitches max-pack create failures above c=880".

    data/agent/rlp-redswitches-c0p025-max1-m100/concurrency_20260828_225238_n50.jsonl

**Result: 704 → 2000, six levels, 62,464 episodes, zero failures.**

```
     c     runs  fails  tput/s  exec_wall_s   p50_ms   checksum_ok
   704     5632      0    6.89        817.4    99345   True
   880     7040      0    6.83       1031.2   127179   True
  1056     8448      0    6.80       1242.7   149671   True
  1408    11264      0    6.81       1655.0   195912   True
  1760    14080      0    6.84       2059.8   244756   True
  2000    16000      0    6.82       2346.5   279770   True
```

`END_EXIT=0`, every level `distinct_checksums: 1` / `checksum_ok: true`, zero
"no matching capacity" errors, cell drained to 0 live VMs afterwards.
On-node client (`client_host: rs-vl-us-15`), n=50, seed=42, `-E 8`,
`--hold-then-exec`, image `dtgraviet/vera-agent-benchmark:v3`.

Throughput is flat (~6.8 jobs/s) across a 3x concurrency range: the box
saturates fairly rather than collapsing. It is lower than Phoenix (~19 jobs/s)
because this host has 128 threads against Phoenix's 384, and these sandboxes
burst to a full vCPU each — load1 reached 2063 at c=2000.

## The ticket's diagnosis was wrong in two specific ways

**1. `RLP_MAX_LIVE_VMS` was never 512 — it was 1300, and it was not binding.**
The old ceiling was the CPU ledger:

    128 threads x 0.99 (RLP_RESERVE_PCT) / 0.125 cpu per sandbox = 1013 sandboxes

**2. The `~512` plateau was `1013 - ~500 leaked sandboxes`.** At the time of the
failing waves the cell was holding ~500 sandboxes left over from earlier
cancelled waves, so only ~513 slots remained — hence `fails(c) ~ c - 512`.
1017 leaked sandboxes were still live when this work started; the `jobs` table
contained *no* delete jobs for them, so they were client-abandonment leaks, not
a teardown failure. `scripts/phoenix_rlp_cleanup_sandboxes.py` cleared them.

Separately, the create consumer `JOBS/runner-vm-redswitches` was **wedged** at
`ack_pending 2048/2048`, `redelivered 2049`, stuck since 20:46 UTC (the
cancelled c=1760 wave). While wedged, *every* create in the cell fails with
"create job not picked up by any runner within 60s (no matching capacity)" even
though the cell is empty and idle. Deleting the durable while the runner was
live did **not** self-heal; a full `systemctl restart rlp-runner` was required.
The identical wedge was observed on Phoenix the same day — see
`tickets/phoenix-vera-matched-ladder-BROKEN.md`.

## Why 1056+ could not fit before (and does now)

At the old 0.125 cpu / 512 MiB shape the cell tops out at 1013 sandboxes, so
1056 and everything above it was over the ceiling on an *empty* cell. No knob
raises that: 2000 sandboxes at 0.125 cpu need 250 cpu of ledger on a 128-thread
box.

The fix is a smaller guarantee. At **0.025 cpu / 100 MiB** the ceilings become:

| axis | ceiling at new shape |
|---|---|
| cpu (`128 x 0.99 / 0.025`) | 5068 |
| memory (`1,148,669 MiB / 102`) | 11,261 |
| scratch (`3,624,430 MiB / 1024`) | 3539 |
| `RLP_MAX_LIVE_VMS` | **2500** (now the binding axis) |

At c=2000 the CPU reservation is 50 of 126.72 — 40% of the ledger, against 100%
before.

## Cell configuration used (all env — no code change)

`/etc/rlp/api.env` (backup: `/etc/rlp/api.env.bak.20260828_220749`):

```
RLP_MIN_CPU=0.025          # was default 0.125 — the clamp blocking sub-0.125
RLP_MIN_MEM_MIB=100        # was default 512
RLP_MIN_SCRATCH_MIB=1024   # was 3072; 3072 x 2000 = 6.1 TiB > 3.5 TiB available
RLP_BURST_MAX_CPU=1        # per-sandbox burst cap: 1 vCPU (unchanged)
RLP_BURST_MAX_MEM_MIB=4096 # per-sandbox burst cap: 4 GiB (was default 32768)
```

`/etc/rlp/runner.env` (backup: `/etc/rlp/runner.env.bak2.*`):

```
RLP_MAX_LIVE_VMS=2500      # was 1300 — would have bound at 2000
RLP_NETNS_POOL=2100        # was 1280 — pre-warm so 2000 creates skip the
                           # synchronous RTNL fallback
RLP_VM_CONCURRENCY=128     # was 64 — halve create queue time under a 2000 burst
```

**100 MiB is not arbitrary.** The API enforces a mandatory memory-proportional
CPU floor (`RLP_MEM_MIB_PER_CPU`, default 4096). At 100 MiB the floor computes
`ceil(100*1000/4096)/1000 = 0.025` — exactly the requested CPU, so the floor
lands on the request instead of clamping it up. Asking for 0.025 cpu with more
memory than ~102 MiB silently raises the reservation again.

Verified resolved shape in `vms`: `cpu 0.025 / mem_mib 102 / vcpus 1 /
scratch_mib 1024 / mode burstable`.

Note the SDK on the cell host has no `cpu_max` / `memory_max` fields, so
`--rlp-cpu-max` / `--rlp-memory-max` are advisory only — the burst caps that
actually apply are the cell's `RLP_BURST_MAX_*` values above.

## Reproduce

```bash
cd /root/arm64-benchmark-1
./.venv/bin/python main.py --benchmark agent --runner rlp --target redswitches \
  --snapshot dtgraviet/vera-agent-benchmark:v3 \
  --levels 704 880 1056 1408 1760 2000 \
  --n 50 --seed 42 -E 8 --hold-then-exec \
  --rlp-cpu 0.025 --rlp-cpu-max 1 --rlp-memory 0.1 --rlp-memory-max 4 --rlp-disk 1 \
  --output data/agent/rlp-redswitches-c0p025-max1-m100/concurrency_$(date -u +%Y%m%d_%H%M%S)_n50.jsonl
```

Preconditions, in order:

1. `./.venv/bin/python scripts/phoenix_rlp_cleanup_sandboxes.py` (works against
   any cell; reads `RLP_API_URL`/`RLP_API_KEY` from `.env`).
2. Check the create consumer is not wedged:
   `nats -s nats://$TOKEN@127.0.0.1:4222 consumer info JOBS runner-vm-redswitches`
   — `Outstanding Acks` must be well below 2048 and `Waiting Pulls` > 0. If it
   is saturated, `consumer rm` **and restart the runner**.
3. Confirm `gate_open: true` and `live_vms: 0` in `runners.capacity`.

A `systemctl restart rlp-runner` on this host takes ~8 minutes: `sudo` costs
~72 s wall / 45 s system per invocation here (1M `RLIMIT_NOFILE` fd-close loop),
and the netns pool pre-warms 2100 namespaces. The VM hot path is unaffected
(netns ops use netlink, `impl=netlink`).

## Not comparable with the Vera/Phoenix 0.125 series

This is a new series (`c0p025`, 100 MiB) and must not be plotted on the same
axis as the `c0p125` m512 ladders as if it were the same experiment — the
per-sandbox guarantee is 5x smaller. It answers "how many sandboxes fit on this
box", not "how does Zen 5 compare to Vera at a fixed guarantee".

## Known gap

`RLP_CREATE_MAX_QUEUE_SECS` cannot be raised above 60 s: the API clamps it
(`raw.min(CREATE_MAX_QUEUE_SECS_CAP)`, `api/src/events/mod.rs`). Setting 180 is
silently a no-op, so it was removed from `api.env` rather than left misleading.
This run did not need it, but a slower cell hitting create-queue timeouts cannot
be tuned out of them without a platform code change.
