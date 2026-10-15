# Graviton5 bench cell (AWS m9gd.metal-48xl, us-east-1), 2026-10-14

Set up as a copy of the HQ Vera cell (`../vera-hq-cell-20261014/`).

## Host
- `ssh ubuntu@<graviton5-host>` (private 172.31.5.229). m9gd.metal-48xl: Neoverse-V3, 192 cores, no SMT, 1 socket,
  **2 NUMA nodes** (0-95, 96-191), 754 GiB. Ubuntu 24.04, kernel 6.17.0-1017-aws, **4 KiB pages** (Vera: 64 KiB).
- Data: instance-store `nvme0n1` (3.5 TB, ext4) at `/mnt/data`, the same single-NVMe layout as Vera. `nvme1n1`/`nvme2n1` unused.
  Instance store is wiped on stop/start (it survives a reboot).
- Kernel cmdline adds `numa_balancing=disable init_on_alloc=0`, matching Vera. `preempt=none` is impossible: the AWS kernel is
  built with PREEMPT_VOLUNTARY and no PREEMPT_DYNAMIC. A 64 KiB AWS kernel (`linux-image-6.17.0-*-aws-64k`) is available for a page-size A/B.
- Every host change is logged in `/etc/rlp/HOSTCHANGES`: /etc/hosts hostname, sysctl 90-rlp-bench.conf (ARP 65536, conntrack 1M),
  the udev iscsi shadow, grub, disk.
- The first host offered (<graviton5-host-abandoned>, m9g without instance store) was abandoned after host prep.

## Software: identical to HQ Vera (checksums match)
runner `353a4060945c`, proxy `d1e93049f417`, api `c49d24e5ac54` (reproducible rebuild), firecracker v1.16.1 `71ca07335765`,
daemon `rlp-rs-0.4.1` with layer diff_id `a1cd17bd…` (byte-identical), guest kernel 6.12.34-rlp1-arm64. Config is the same as
Vera's `runner.env`/`api.env` (`RLP_FC_SOCK_WAIT_MS=30000`, `VM_CONCURRENCY=512`, `NETNS_POOL=2100`, `BALLOON=0`, min shape
0.025 CPU / 64 MiB). Event auditing is at the platform default. Region, cpu_type and runner are `graviton5` / `graviton5-1`.

## Harness
`~/arm64-benchmark-1` (Daniel's harness from the `benchmark-methodology` branch, including the methodology doc, preflight and mpfleet),
plus the `graviton5` target (`harness-graviton5-target.patch`, uncommitted). The SDK is rlp-sdk 0.4.0 (the 9575F copy). `.env` uses `G5_RLP_*`.
`bench-preflight` and `bench-startup N REPS` are installed in `/usr/local/bin`, and `bench-startup` defaults to `TARGET=graviton5`.

## Findings
All results, analysis and corrections are in **`FINDINGS.md`**. Scripts are in `scripts/` and raw data is in `bench-results.tgz`.
The methodology lessons are folded into the harness `docs/benchmark-methodology.md` (§0, §3, §4a).

Final host state: 4 KiB kernel (default; the 64 KiB kernel is installed, use `grub-reboot` for a one-shot boot), rlp.slice unpinned, no sandboxes.

## First result (superseded by FINDINGS.md): 1,000-sandbox create-ready, unpinned (both NUMA nodes), single-process client
| rep | ok | all ready | p50 | p95 |
|---|---|---|---|---|
| 1 | 1000/1000 | 8.48 s | 4.12 s | 6.25 s |
| 2 | 1000/1000 | 8.54 s | 4.73 s | 6.16 s |
| 3 | 1000/1000 | 7.25 s | 4.12 s | 5.84 s |
0 socket-wait timeouts and 0 self-cordons. For comparison, HQ Vera: socket 0 pinned 8.4–10.6 s, unpinned 20–23 s.
