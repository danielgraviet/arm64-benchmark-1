## What

Every snapshot clone (template hit, the common create path) copies the template's 16 MiB init disk to a private per-clone file on the runner's scratch filesystem and **fsyncs it**, inside the clone's critical path:

- `runner/internal/vm/template.go:1401-1415` (`main` @ `d78c74689`): `privInitdisk = <scratchDir>/<vmID>.initdisk.ext4`, then `copyFileContents(src, privInitdisk)`.
- `runner/internal/vm/vm.go:3308-3330`: `copyFileContents` is `io.Copy`, then `out.Sync()`.

The code comment at `template.go:1401-1409` says why the copy exists: Firecracker reopens `vda` read-write at snapshot load, so clones must not share one master. It also says the content doesn't matter: "The resumed guest has already pivoted off vda (it does NOT re-run /init), so the content is irrelevant — it just needs a private writable target."

So each clone writes 16 MiB of irrelevant data and forces it to stable storage. A 1,000-sandbox burst writes ~16 GB and issues 1,000 fsyncs within a couple of seconds.

## Measured

On the HQ Vera benchmark cell (runner built from `f0611fa13`; this code is unchanged on `main`), with the scratch dir on the root NVMe (ext4). Each burst was 1,000 creates of an idle image (`alpine:3.20`) from 16 client processes, measured per sandbox from runner `boot-phases` plus `bpftrace`/`iostat`:

| | unloaded (one at a time) | 1k burst |
|---|---|---|
| `scratch_cp_ms` (scratch `cp` + init-disk copy + fsync + links), p50 / p90 | 7 / 8 ms | **313 / 756 ms** |
| init-disk `fsync` latency | ~0 | **64 ms – 1 s** (1,000 calls) |
| `cp --sparse` of the scratch file itself | | 2–8 ms |
| system NVMe during the burst | | **~6 GB/s, 97% utilization for ~2 s**, w_await 40–90 ms |
| opening files in the shared scratch dir | | up to 256 ms |

**A/B with no code change:** `RLP_LOCAL_SCRATCH` pointed at a tmpfs, 2 bursts vs 4 on disk, interleaved.
- `scratch_cp_ms` p50 drops from 313 to 10 ms.
- POST → sandbox running drops from p50 2.09 s / p90 3.16 s to **p50 1.49 s / p90 2.44 s (−28%)**.

That is the upper bound of the gain from removing this I/O. Part of the saved time moves into the next serial step: cgroup creation, filed separately.

## Why it matters

On a dense host, create bursts are bound by this per-clone disk write, not by CPU. The fsync also competes with every other writer on the scratch filesystem: template builds, cold boots, guest scratch I/O.

## Options (for discussion, not decided)

- Create the private target without copying: a sparse file of the master's size (`truncate`), or a reflink where the filesystem supports it. This is only valid if nothing reads the init disk after resume; the comment says nothing does.
- If a copy is needed, drop the `fsync`. The file is per-clone scratch that is deleted at teardown, so durability buys nothing.
- Keep the per-clone init disks on tmpfs (the run dir is already tmpfs).

Each needs care around the PLAN-VANISH-REGRESSION root cause B guarantee, which is that no two clones share a writable `vda`.

## Related

- #437: orphaned VM-local scratch artifacts. The same cell had 1,460 leftover `*.initdisk.ext4` files (23 GB) from aborted runs.
- The runner derives its scratch capacity from the scratch filesystem size. A small tmpfs (96 GB) admitted only ~95 sandboxes (`capacity gate … nak-routing to a peer`), so any tmpfs option has to account for that.

Found while measuring the create path step by step on NVIDIA Vera (benchmark investigation, 2026-10-14). Raw data available on request.
