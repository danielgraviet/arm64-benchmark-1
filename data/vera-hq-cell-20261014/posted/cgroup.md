## What

Every sandbox create makes a per-VM cgroup on the clone's critical path, and the kernel serializes cgroup creation:

- `runner/internal/vm/template.go:1453` (`main` @ `d78c74689`): `m.setupCgroup(...)`, which calls `runner/internal/vm/cgroup.go:225-245`: `os.Mkdir(rlp.slice/vms/vm-<id>)` and then writes `cpu.weight`.
- `runner/cmd/rlp-fcns/main.go:73-78`: the spawned helper then joins the cgroup by writing `cgroup.procs` before it execs Firecracker.

`deploy/rlp-cgroup-setup` enables `cpu memory pids` under `rlp.slice/vms`, and `memory` is required there (usage tracking, admission floors, balloon bound; see the script header). Creating a cgroup with the memory controller allocates per-CPU state, so its cost grows with the host's CPU count. Creations in one parent directory also queue behind each other.

## Measured

On the HQ Vera cell (352 CPUs, kernel `6.17.0-1032-nvidia-64k`, runner from `f0611fa13`; this code is unchanged on `main`).

**Kernel floor**, 1,000 `mkdir`s in a throwaway cgroup under `rlp.slice`, host otherwise idle:

| controllers | 256 in parallel | serial |
|---|---|---|
| `cpu memory pids` (what `rlp-cgroup-setup` configures) | **0.86 s** | 1.21 s |
| `cpu memory` | 0.88 s | 1.20 s |
| `cpu` only | 0.47 s | 0.92 s |

Parallelism barely helps. **Each 1,000-sandbox burst carries ~0.9 s of strictly serial cgroup creation.**

**In a real burst** (1,000 creates, idle image, 16 client processes), measured with `bpftrace`:
- The kernel's `cgroup_mkdir` takes 0.5–2 ms per call, but the `mkdir` syscall takes **64–512 ms** (mode 256–512 ms), because creates wait in line.
- The un-instrumented part of `clone_ms` (cgroup mkdir + `cpu.weight` + instance registration) goes from 3 ms unloaded to **p50 157 ms / p90 417 ms**.
- The `cgroup.procs` join by `rlp-fcns` takes 16–128 ms under the burst. It falls inside `fc_start_ms`.
- With the scratch-disk bottleneck removed (scratch on tmpfs, see the init-disk issue), this step becomes the largest runner cost: **p50 498 ms / p90 637 ms**.

Ruled out on the same host:
- Go fork serialization: forks of `cp`/`rlp-fcns`/`nft` overlap, up to 36 at once.
- cgroup2 `favordynmods`: cgroup joins got cheaper in some runs, but end-to-end burst time was unchanged.

## Why it matters

Burst throughput per host is capped by a serial kernel resource that grows with core count. Bigger hosts (Vera: 352 CPUs) pay more per cgroup, not less.

## Options (for discussion, not decided)

- **Pre-create cgroups in a warm pool**, as the netns pool already does for network namespaces. A clone takes a ready `vm-<slot>` cgroup, sets `cpu.weight`, and the pool refills off the hot path. Teardown recycles or removes the cgroup in the background.
- **Spawn Firecracker directly into its cgroup** with `clone3(CLONE_INTO_CGROUP)`. Go supports this via `SysProcAttr.UseCgroupFD`/`CgroupFD`. It replaces the `cgroup.procs` migration, which takes the thread-group rwsem for write.
- Nest per-VM cgroups under several parents (e.g. shard by slot) if parent-directory lock contention proves to be a large share of the wait.

## Related

- #2916: dirless reap leaves the `vm-<id>` cgroup behind.
- #1718: `cpu.weight` write fails on the preview runner.

Found while measuring the create path step by step on NVIDIA Vera (benchmark investigation, 2026-10-14). Raw data and scripts available on request.
