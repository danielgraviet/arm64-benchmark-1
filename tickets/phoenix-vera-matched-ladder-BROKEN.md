# Phoenix m512 ladder matched to Vera levels — BROKEN RUN (2026-08-28)

**Do not chart this file.** It is committed as evidence for the platform bugs it
exposed, not as a Zen 5 result.

    data/agent/rlp-phoenix-c0p125-max1-m512/concurrency_20260828_194036_n50.jsonl

Ticket: "Phoenix agent ladder — match Vera concurrency levels" (Daniel, 2026-08-28).
Only levels **704 / 880 / 1056** are valid. Everything from 1408 up is a platform
failure, not a capacity measurement.

## What was run

Per the ticket, exactly:

| Knob | Value |
|------|-------|
| levels | `704 880 1056 1408 1760 2112 2464 2784` |
| `--n` / `--seed` / `-E` | 50 / 42 / 8 |
| cpu | `--rlp-cpu 0.125 --rlp-cpu-max 1` |
| memory | `--rlp-memory 0.5` (512 MiB) |
| mode | `--hold-then-exec` |
| target / snapshot | `us-phoenix-1` / `dtgraviet/vera-agent-benchmark:v3` |

Client was **on-cell** (`client_host=rlp-phx-cell-api-vnic`, `api_url=http://127.0.0.1:8088`),
not a laptop. Runner `runner-oc5002` (BM.DenseIO.E6.Ax.192, 384 cores, 2.26 TiB).
`uv` is not installed on that host; `./.venv/bin/python` was used (same interpreter
`uv run` would select). `ulimit -n` raised to 1048576.

## Results

```
     c     runs  fails   tput/s  exec_wall_s    p50_ms
   704     5632      0    19.27        292.3     29915
   880     7040      0    19.27        365.3     31688
  1056     8448      0    18.19        464.4     34914
  1408     4201   1009    24.62        170.6     18882   <- platform failure begins
  1760     1760   1760     0.00          0.0         0   <- 100% create failure
  2112     2112   2112     0.00          0.0         0
  2464     2464   2464     0.00          0.0         0
  2784     2784   2784     0.00          0.0         0
```

704–1056 are clean and on-profile (19.3 → 18.2 jobs/s, matching the
`rlp-phoenix-c0p125-max1/concurrency_20260827_221130_n50.jsonl` ARP-fix run).
`END_EXIT=0`; the harness completed, the cell did not.

Every failure string is
`create job not picked up by any runner within 60s (no matching capacity)`.
That message is misleading — the cell had capacity. See below.

## Root cause: two independent control-plane defects

### 1. A wedged JetStream create consumer (hit before the run started)

`JOBS/runner-vm-us-phoenix-1` (`AckWait 1m`, `MaxDeliver 20`, `MaxAckPending 2048`)
was sitting at **`Outstanding Acks: 2048 / 2048`, `Redelivered: 2048`,
`Unprocessed: 0`**, last ack 3h39m earlier — i.e. since Daniel's laptop run died at
~15:56 UTC. With the ack window saturated NATS delivers nothing, so *every* create
in the region timed out and the API reported "no matching capacity" while the
runner was online, idle and advertising 0 live VMs.

This state is permanent: the messages were already removed from the WorkQueue
stream, so nothing can ever ack them.

Recovery used: stop `rlp-runner` → `nats consumer rm JOBS runner-vm-us-phoenix-1`
→ start `rlp-runner` (the durable is recreated on startup). After that, a smoke
level and 704/880/1056 ran with zero failures.

Also cleaned up first: **2876 orphaned sandboxes** left live by that same laptop
run (`scripts/phoenix_rlp_cleanup_sandboxes.py`, added in this branch — the script
the ticket refers to did not exist in the repo).

### 2. The runner stopped pulling both job streams mid-run (killed this run)

At ~20:00 UTC, during level 1408, `runner-oc5002` stopped issuing pull requests on
**both** durables while continuing to heartbeat normally:

```
JOBS/runner-vm-us-phoenix-1      Outstanding 1009   Waiting Pulls 0
DELETES/runner-delete-oc5002     Unprocessed 6582   Waiting Pulls 0
```

Its own capacity doc still claimed `"consuming": true`. Because deletes stopped
being pulled, nothing was torn down, and reservations only accumulated:

```
live_vms      3048
reserved.cpu  381      of total 384      <- 3048 x 0.125
reserved.mem  1560576  MiB               <- 3048 x 512
usage_floor   {cpu: 0, mem_mib: 0}
used.mem      600479   MiB               <- ~197 MiB actual RSS per sandbox
gate_open     false
```

`reserve_pct=99` closes the admission gate at 380.16 reserved cpu, so once the
orphans reached 3048 the gate shut permanently and levels 1760+ failed 100%.

The 1009 failures at level 1408 equal exactly the 1009 outstanding acks: those
creates were cancelled by the API after `RLP_CREATE_MAX_QUEUE_SECS` (60s) and
reported as failures to the client, but the runner booted them anyway. They became
orphans with terminal control-plane rows and nothing reclaims them.

The host ended up thrashing (load 237 → 275 and rising, sshd unschedulable) and
required an out-of-band reset.

## Reservation accounting — checked, and it explains the two Vera series

Per-sandbox reservation on this run was exactly what was requested: **0.125 cpu /
512 MiB**, with `usage_floor` zero (the runner-side usage floor,
`RLP_MEM_MIB_PER_CPU`, is not enabled on this runner) and actual RSS ~197 MiB.
No hidden inflation on the m512 ladder.

It is *not* neutral on the 1 GiB ladder. rl-platform enforces a mandatory
memory-proportional CPU floor (`api/src/vms/entities.rs`, `RLP_MEM_MIB_PER_CPU`,
default 4096 => 1 core : 4 GiB): a create is silently clamped up to
`mem_mib / 4096` cores.

| series | requested mem | reserved cpu/sandbox | oc5002 ceiling (384 x 0.99 / cpu) |
|---|---|---|---|
| `rlp-vera-c0p125-max1` (1 GiB, `rlp_memory: null`) | 1024 MiB | **0.25** (not 0.125) | 1520 |
| `*-m512` (`--rlp-memory 0.5`) | 512 MiB | 0.125 | **3041** |

So the 1 GiB series reserves double what its folder name suggests, and the m512
ladder exists precisely to double packing density. 3041 is exactly the top level
of the good `221130` run — that ladder was built from this ceiling.

(The 0.25 figure for Vera is inferred from that file's `rlp_memory: null` meta plus
the API's ratio floor; it was not measured on the Vera cell.)

## Before rerunning

1. Reset / drain `runner-oc5002` and confirm `gate_open: true`, `live_vms: 0`.
2. Check `JOBS/runner-vm-us-phoenix-1` is not saturated
   (`Outstanding Acks` well below 2048, `Waiting Pulls` > 0) — recreate the durable
   if it is.
3. Run `scripts/phoenix_rlp_cleanup_sandboxes.py` to clear leftovers.
4. Consider raising `RLP_CREATE_MAX_QUEUE_SECS` above 60s on the cell API: at these
   burst sizes the 60s cancel window is what converts a slow create burst into
   permanently orphaned VMs.

The headroom is thin by design: 2784 requested vs a 3041 ceiling is 8%, so any
teardown lag or orphan accumulation between levels breaks the top of the ladder.
