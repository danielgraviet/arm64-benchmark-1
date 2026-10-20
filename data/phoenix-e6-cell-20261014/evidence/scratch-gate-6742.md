# The 6,742 scratch-reservation gate — evidence status

**The raw journal for this window (2026-10-14 17:45–17:55 UTC) has rotated out.** journald on this
host keeps ~219 MB and, after the density runs, its oldest `rlp-runner` record is 19:05:56Z. The
per-level `*.journal` files captured by `ph-ladder.sh` are from the 14:00 burst ladder, where the
limiter was the 60 s pickup cap, not this gate — they contain no `capacity gate` lines.

## What was read live, and recorded in FINDINGS.md at the time

Runner log line, repeating every ~30 s while the fleet stood at 6,742 (17:48:01Z–17:52:59Z):

```
level=WARN msg="capacity gate: reserved+pending over threshold; nak-routing to a peer"
  reserved="{Cpu:168.55 MemMiB:431488 ScratchMiB:6903808 Gpus:0}"
  pending="{Cpu:0 MemMiB:0 ScratchMiB:0 Gpus:0}"
  reserve_pct=95
  total="{Cpu:384 MemMiB:2321663 ScratchMiB:7266782 Gpus:0}"
```

Postgres, same moment:

```
select scratch_mib, count(*) from vms where status='running' group by 1;
 1024 | 6742
```

## Why the claim stands without the journal

The gate is arithmetic, and it is reproducible from numbers that *are* preserved:

```
0.95 × 7,266,782 MiB (scratch total)  = 6,903,443 MiB  available to reserve
6,903,808 MiB reserved ÷ 6,742 VMs    = 1,024.0 MiB    per sandbox
6,903,443 ÷ 1,024                     = 6,741.6        → 6,742 admitted, the next one refused
```

and it was hit **four independent times** — run logs preserved in `runs.tgz`:

| run dir | stop |
|---|---|
| `waves-20261014_144414` | 6,742 |
| `waves-20261014_153130` | 6,743 (cap raised to 900 s — same wall) |
| `waves-20261014_162247` | 6,742 (`MAX_LIVE_VMS` 20,000 — same wall) |
| `waves-20261014_172933` | 6,742 (`MAX_LIVE_VMS` 20,000 — same wall) |

The fifth run, after the scratch request was actually reduced to 64 MiB
(`waves-20261014_180617`), cleared the wall and reached 8,000 — which is the control experiment
that confirms scratch, not anything else, was the binding resource.

**Caveat worth stating plainly:** all four of those runs requested 1 GiB because two `scp`
invocations silently failed, so the reduced-scratch variable was not actually applied until the
fifth run. They are therefore four repetitions of one experiment, not four independent variations —
their value is that the stop point is exactly reproducible, not that four different configurations
converged.
