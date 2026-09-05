# Ian Finder briefing: Vera vs Zen 5 (9J45) through 2,000

Internal cheat sheet. Answers are what we actually ran for [`nvidia-agent-brief-maxpack.md`](nvidia-agent-brief-maxpack.md), not what a perfect silicon lab would have pinned. If we did not measure it, the answer says so.

Audience: Ian Finder (NVIDIA CPU). He will grind on topology, NUMA, SMT, memory locality, sockets, regions, and packing knobs. Lead with the honest config. Do not volunteer marketing.

Headline result you can defend: **same agent image, same seed, same concurrency ladder, both dual-socket, both on-node clients, both 0.125 vCPU guarantee with 1 vCPU burst. Throughput stays near 22 jobs/s on Vera and near 18.8 jobs/s on 9J45 from 880 through 2,000.**

---

## 1. What did you actually compare?

**Q: Is this a chip bake-off or a product bake-off?**

**A:** Product-shaped chip time. Each sandbox is a Firecracker microVM on Daytona RLP. The metric we quote for silicon is `duration_ms` (time inside the guest doing the agent loop). Throughput is completed episodes divided by the exec-wave wall after the fleet is already up. Create, delete, and client RTT are not in `duration_ms`.

**Q: Same workload on both machines?**

**A:** Yes. Task `repo-agent-v3`. Image `dtgraviet/vera-agent-benchmark:v3` (multi-arch amd64 + arm64). `--n 50`, seed 42, `-E 8` episodes per sandbox. No LLM. Seed a broken Python package, search, AST walk, oracle patches, heavy pytest. Successful episodes return a checksum. Checksums match within an ISA. They differ across aarch64 vs x86_64 because generated trees and Python hashes are arch-specific. That is not a work mismatch.

**Q: Same concurrency points?**

**A:** Yes, on the x-axis:

```text
44  88  132  176  264  352  528  704  880  1056  1408  1760  2000
```

**Q: One node or a fleet?**

**A:** One node per series. Vera creates all landed on `ipp8-d15-c2-vera-2`. Phoenix creates all landed on `oc5002`. Not a multi-host spread. Do not let anyone explain 9J45 results as "many EPYC boxes."

---

## 2. Machines, sockets, cores, SMT

**Q: What is the Vera box?**

**A:** Dual-socket NVIDIA Olympus / Vera cell. Hostname `ipp8-d15-c2-vera-2`. Captured `lscpu` (2026-08-24, before a Firecracker binary swap, topology unchanged):

- Model name: Olympus
- Sockets: 2
- Cores per socket: 88
- Physical cores: 176
- Thread(s) per core: 2
- Logical CPUs: 352 (`nproc` 352, online `0-351`)
- SMT active: `/sys/devices/system/cpu/smt/active` = 1
- CPU scaling MHz reported: 100%
- Guest probe `cpu_model`: `0x010`
- Host ISA: aarch64, SVE2 and FP8 flags present (`sve2`, `f8fma`, `f8dp4`, `f8e4m3`, `f8e5m2`)
- RAM (from an Aug 26 capacity debug): about 1.4 TiB total, ~259 GiB used while packed. Not a RAM cliff for this ladder.

**Q: What is the 9J45 box?**

**A:** Dual-socket AMD EPYC Turin (Zen 5) cell. Hostname `oc5002`. Region `us-phoenix-1`. `lscpu` captured on the box (2026-09-01):

- Model name: `AMD EPYC 9J45 128-Core Processor` (OEM string). Linux topology is **96 cores per socket × 2 sockets = 192 physical cores**, not 128. Use the sysfs/Linux counts if he pushes on the name.
- Vendor: AuthenticAMD. Family 26, model 2, stepping 1.
- Sockets: 2
- Cores per socket: 96
- Thread(s) per core: 2
- Logical CPUs: **384** (online `0-383`)
- Address sizes: 52-bit physical, 57-bit virtual (`la57`)
- Frequency boost: **enabled**
- CPU max MHz: **4122.75**. Min MHz: **1212.58**
- `CPU(s) scaling MHz` at capture: **52%** (snapshot of current vs max at `lscpu` time, not a locked policy). Vera's comparable field was 100%.
- Virtualization: **AMD-V** (`svm`)
- Guest probe: `cpu_model` = `AMD EPYC`, `arch` = `x86_64`

Caches (sum of all, from `lscpu`):

- L1d: 9 MiB (192 instances) → 48 KiB data per core
- L1i: 6 MiB (192 instances) → 32 KiB instr per core
- L2: 192 MiB (192 instances) → 1 MiB per core
- L3: **1 GiB (32 instances)** → 32 MiB per L3 slice. 16 slices per socket if split evenly.

We still do **not** have NPS mode, CCD enable-mask, or `lscpu -e` / `lstopo` in this folder. Do not invent NPS1 vs NPS2. 32 L3 instances on 192 cores is consistent with multiple CCDs per socket. If he wants CCD maps, pull `lscpu -e` and `/sys/devices/system/cpu/cpu0/cache`.

**Q: Dual-socket on both. Did you fill one socket first?**

**A:** No pinning that would force that. Engineering already falsified the "Vera dies at 88 because it filled socket 0" story. Linux spreads Firecracker vCPU threads across both sockets. An in-guest spin stayed flat through 132 busy guests. Early jobs/s flattening at 88–176 on Vera was an **SSH laptop tunnel cap**, not a socket wall. These brief runs are on-node, so that cap is gone. 9J45 is the same shape: two NUMA nodes, no cpuset, both sockets eligible.

**Q: Was SMT on?**

**A:** Yes on both. Vera: 176c / 352t. 9J45: 192c / 384t, `Thread(s) per core: 2`. We did **not** run an SMT-off control on either machine for this ladder. If he wants SMT-off, that is a new experiment.

**Q: Did the guest see one vCPU or the whole host?**

**A:** Guest probe `cpu_count` = 1 on both series. Each sandbox is a 1-vCPU Firecracker VM (burst cap 1). It does not see 176 or 192 host cores.

**Q: Frequency / governor / turbo?**

**A:** We did not pin `performance` vs `schedutil`, did not disable boost, did not capture per-core MHz during the 2,000 wave.

What `lscpu` shows:

- Vera (Aug 24 capture): `CPU(s) scaling MHz: 100%`
- 9J45 (Sep 1 capture on `oc5002`): boost **enabled**, max **~4.12 GHz**, min **~1.21 GHz**, scaling MHz **52% at that instant**

52% is not "the chip is a 2 GHz part." It is `lscpu`'s current-vs-max snapshot. That SSH session also had a tiny agent smoke on the box, so many cores can sit near min while idle. Packed 2,000-VM waves will boost some cores and park others. We do **not** have a histogram of MHz during the pinned JSONL runs.

If he says 9J45 lost because it was at half clock: we cannot prove or disprove from this dump. Offer a rerun with `cpupower frequency-set -g performance` plus `perf stat` / `amd_pstate` traces on both cells.

**Q: AVX-512 / CAT / MBA? Did you use them?**

**A:** Host flags include AVX-512, `avx_vnni`, `avx512_bf16`, `cat_l3`, `cdp_l3`, `mba`, `cqm_*`. This agent loop is CPython + pytest. We did not pin L3 CAT, did not set MBA bandwidth throttling, did not compile with AVX-512. Those features are available on the host. They are not how we scheduled sandboxes.

**Q: Spectre mitigations on 9J45?**

**A:** Default kernel mitigations, including Spectre v2 Enhanced/Automatic IBRS, IBPB conditional, **STIBP always-on**, SSB via prctl, spec rstack overflow reduced speculation, Vmscape IBPB on userspace exit. We did not disable mitigations for the brief. Vera has its own ARM64 mitigation set. We did not run a mitigations-off compare.

**Q: Isolated machine? Other tenants?**

**A:** Vera is a shared vendor cell. Phoenix `oc5002` is our RLP runner for that region, still not a lab-isolated "one process, rest of CPUs offlined" setup. RLP, NATS, Firecracker, the harness client, and any leftover sandboxes share the node. We cleaned leftover sandboxes before high-c Phoenix runs. We did not use `isolcpus`, `nohz_full`, or IRQ pinning.

---

## 3. NUMA and memory locality

**Q: Vera NUMA layout?**

**A:** Two populated nodes. Nodes 2 and 3 exist in sysfs and are empty.

```text
NUMA node0 CPU(s): 0-87,176-263
NUMA node1 CPU(s): 88-175,264-351
```

Classic 2-way SMT layout: physical cores first, SMT siblings in the upper half. Socket 0 ≈ node0 (cores 0–87 plus siblings 176–263). Socket 1 ≈ node1.

**Q: 9J45 NUMA layout?**

**A:** Two nodes. Same SMT-sibling-high pattern as Vera.

```text
NUMA node(s):       2
NUMA node0 CPU(s):  0-95,192-287
NUMA node1 CPU(s):  96-191,288-383
```

Socket 0 ≈ node0: physical 0–95, SMT siblings 192–287. Socket 1 ≈ node1: physical 96–191, siblings 288–383. 96 physical CPUs per node before SMT, 192 logical per node. Firmware is NPS=2 style (one NUMA node per socket). We did not confirm AMD `NPS` BIOS string beyond this `lscpu` map.

**Q: Did you pin sandboxes to one NUMA node?**

**A:** **No.** JSONL meta has `numa_node: null` and `host_cpus: null` on both series. `--numa-node` in this repo is **Docker-only**. These runs are RLP Firecracker. We did not pass `cpuset`, `numactl --cpunodebind`, or `--membind` to jailer/Firecracker for this brief.

**Q: Local memory or remote (cross-socket) memory?**

**A:** **Not controlled.** Guest RAM is host-backed Firecracker memory. Without a mempolicy, first-touch / interleave can place pages on either socket. Cross-socket (remote) accesses are possible, especially at 2,000 live VMs. We did **not** measure `%local` vs `%remote` with `numastat`, `perf mem`, or uncore counters on this ladder.

A separate Docker `mbw` probe on Vera: unpinned MEMCPY ~24,881 MiB/s vs NUMA node0 pinned ~24,765 MiB/s (~0.5%). That is a host copy microbench, **not** this agent ladder, and not a Phoenix compare.

**Q: Did Linux already spread vCPUs so NUMA is "fine"?**

**A:** vCPU threads are spread. That is necessary, not sufficient. Spreading vCPUs without spreading memory can still be remote DRAM. We cannot claim "all memory was local." If he wants a locality-clean rerun, the next experiment is jailer cpuset + mems = same node, then a dual-socket packed run with interleaved memory as the production analog.

**Q: Huge pages? THP? Guest ballooning?**

**A:** Not configured by this harness. 9J45 CPU flags include `pdpe1gb` (1 GiB pages in hardware). That does not mean Firecracker or the guest used them. Do not claim 2M/1G pages were in the path.

**Q: Why empty NUMA node2/node3 on Vera?**

**A:** Firmware/ACPI presents four node slots. Only 0 and 1 have CPUs. Treat it as a 2-node dual-socket machine.

---

## 4. Regions, routing, placement

**Q: What is `--target vera` vs `--target us-phoenix-1`?**

**A:** Two different RLP cells. Not two SKUs in one control plane.

| | Vera | 9J45 (Phoenix) |
|--|------|----------------|
| `--target` | `vera` | `us-phoenix-1` |
| `cpu_arch` on create | `arm64` | unset (x86 default) |
| `cpu_type` | `vera` | unset |
| `mode` | omitted because `--rlp-cpu-max` is set (burstable, not dedicated) | same omit |
| `region_routing` | False (stay on this cell) | False |
| API | cell-local (`VERA_RLP_API_URL`, on-node `http://127.0.0.1:8088`) | Phoenix cell API (`https://api.us-phoenix-1.rlp.trydaytona.com` or LAN equivalent on `oc5002`) |
| Toolbox | on-node `/toolbox` | Phoenix toolbox on that cell |
| Boot image | Docker Hub `dtgraviet/vera-agent-benchmark:v3` | same Hub image, amd64 digest |

**Q: Could Phoenix have scheduled VMs onto another host in the region?**

**A:** Cell DB / prior audits: every create for these ladders is on runner `oc5002`. One-runner region. If he wants a paper trail, we can dump runner IDs from the API for the pinned JSONL timestamps.

**Q: Client on the node or over the WAN?**

**A:** On the node. `client_host` is `ipp8-d15-c2-vera-2` and `oc5002`. Laptop → remote API runs are **not** in this brief. We burned that lesson: SSH tunnel throughput is a TCP cap, and laptop Phoenix under-drove the 192-core box so in-guest time looked too good.

**Q: Why does that matter?**

**A:** Throughput here is exec-wall with a held fleet. If the client is far away, you measure RTT and HTTP pool, not the CPU. Ian will accept on-node. Do not mix in older laptop numbers.

---

## 5. CPU and memory packing knobs (the thing they pick at)

**Q: What does 0.125 vCPU mean? Are you starving the guest?**

**A:** **Guarantee / admission**, not a hard 12.5% cap during the episode.

- `--rlp-cpu 0.125`: runner ledger reserve so we can keep many VMs live.
- `--rlp-cpu-max 1`: burst cap **1.0 vCPU**. Also **omits `mode=dedicated`**. If you forget `--rlp-cpu-max`, Vera dedicated-modes and hits a ~348 Class B wall. Different experiment.
- Cell `RLP_BURST_MAX_CPU=1` is what actually clamps burst if the SDK cannot send `cpu_max`.

During the agent loop the guest may use a full vCPU, subject to CFS sharing when the node is packed.

**Q: Memory 1 GiB vs 512 MiB. Did you throttle the workload?**

**A:** Same split: **guarantee vs burst**.

| Rungs | CPU guarantee | CPU burst | Memory guarantee | Memory burst | Disk |
|------|---------------|-----------|------------------|--------------|------|
| 44–528 (both), Vera 704 | 0.125 | 1.0 | **1 GiB** (harness default `docker_memory=1g`) | cell default / 4 GiB where set | `max(2, memory)` → **2 GiB** |
| Phoenix 704 (glue), both 880–2000 | 0.125 | 1.0 | **512 MiB** (`--rlp-memory 0.5`) | **4 GiB** (`--rlp-memory-max 4` / `RLP_BURST_MAX_MEM_MIB=4096`) | 2 GiB |

The agent is a multi-second pytest/CPU loop. 512 MiB guarantee with 4 GiB burst is a packing knob so 2,000 VMs pass the memory ledger. It is not "the guest only has 512 MiB RSS." If he asks whether RSS stayed under 512 MiB, we did not capture guest `smem` on this ladder.

**Q: Fair compare at 704?**

**A:** **Almost, with one asterisk he will find.** Vera 704 in the headline table is the **1 GiB** base file (`…005637`, p50 25,190 ms, 22.44 /s). Phoenix 704 is the **512 MiB glue** file (`…125904`, p50 31,055 ms, 19.07 /s). We overlaid Phoenix 704 to match the max-pack memory shape and to replace a 1 GiB 704. If he says "704 is not identical memory guarantees," agree, then point at **880+** where both are 0.125 / 512 MiB / 1 vCPU / 4 GiB burst. Throughput gap is still there at 880–2000.

**Q: Overcommit math at 2,000?**

**A:** Reserved CPU = 2000 × 0.125 = **250 vCPU-equivalents**.

- Vera: 250 / 176 physical ≈ **1.42×** vs cores, 250 / 352 ≈ **0.71×** vs SMT threads (reservation). Burst of 1.0 each would be 2000 vCPUs on 176 cores if they all ran at once, which they do not. CFS shares.
- 9J45: 250 / 192 physical ≈ **1.30×** vs cores, 250 / 384 ≈ **0.65×** vs threads.

Live RAM if every VM touched 4 GiB would be 8 TiB, which neither box has. Burst is a cap, not a simultaneous allocation. Admission is on the **guarantee** (512 MiB × 2000 ≈ 1 TiB plus overhead). Vera had ~1.4 TiB. Phoenix DRAM size is not in this folder. If he asks Phoenix `free -h`, pull it from `oc5002`.

**Q: Why not 1.0 vCPU dedicated at 2,000?**

**A:** 2000 dedicated vCPUs will not admit on a 176-core or 192-core box. Fractional guarantee + burst is how production packs agent sandboxes. Dedicated 1 vCPU is a different ladder (older briefs, lower concurrency).

---

## 6. Firecracker, cgroups, storage, networking

**Q: Isolation?**

**A:** Firecracker microVMs, not Docker, for this brief. Vera host had Firecracker **v1.16.1** on PATH at the Aug 24 capture. Jailer was not on PATH in that snapshot. Eng may have swapped binaries later. These agent files are RLP-managed VMs (`sandbox_id` suffix `-vera` / `-us-phoenix-1`).

**Q: vCPU pinning / cpuset inside jailer?**

**A:** Not set by our create path. Scheduler places vCPU threads. No explicit 1:1 core pinning.

**Q: cgroup v1 or v2? CPU quota?**

**A:** Cell default. We did not record cgroup version in JSONL. Burst/quota is whatever RLP applies for burstable mode plus `RLP_BURST_MAX_*`.

**Q: Guest kernels?**

**A:** From in-sandbox probe:

- Vera: `Linux-6.12.34-aarch64-with-glibc2.36`
- 9J45: `Linux-6.8.12-x86_64-with-glibc2.36`

Different kernel series. Same userspace image family (Debian-style glibc 2.36 in the probe string). If he says "kernel is a confounder," that is fair. We did not rebuild a matched 6.12 x86 guest.

**Q: Disk: local NVMe? virtio-blk? overlay?**

**A:** Scratch disk 2 GiB per VM (default). Backing store is the cell's Firecracker disk path (typically host file + virtio). We did not pin NVMe vs NFS for this agent loop. Phoenix and Vera both boot **Docker Hub** images (no west-1 NFS snapshot). Image pull cache on-node. Work is mostly CPU + guest local FS (pytest, generated tree), not a network filesystem benchmark.

**Q: Network path for exec?**

**A:** On-node client → cell API/toolbox on localhost or LAN. vsock/virtio-net to the guest is RLP's usual Firecracker path. We did not instrument PPS or virtio queue depth.

**Q: ARP / create failures on Phoenix?**

**A:** Earlier laptop and pre-fix Phoenix runs failed creates above ~880. Vedran's ARP/netns fix. This brief uses **post-fix on-node** files only. Superseded files are listed in [`sources.md`](sources.md).

---

## 7. Method: hold-then-exec, metrics, sample size

**Q: What is `--hold-then-exec`?**

**A:** Create all `C` sandboxes and wait until started. Then run `-E 8` execs on each. Then delete. Create churn does not overlap episode timing. `cold: false`, `fleet_hold: true` on every run row.

**Q: Throughput definition?**

**A:** `runs / exec_wall_s` for that concurrency wave. Not create-to-delete wall. Not `1 / duration`. Do not quote c=1 throughput as chip speed (too little parallelism).

**Q: `duration_ms` vs `latency_ms`?**

**A:** `duration_ms` is timed inside the sandbox around the agent function. `latency_ms` is client-observed exec including toolbox RTT. Quote **duration** for chip. Quote throughput for density.

**Q: How many samples at 2,000?**

**A:** 2000 sandboxes × 8 episodes = **16,000** completed execs per wave when failures are zero. `--n 50` is the workload scale factor (size of the generated repo / pytest), not the repeat count.

**Q: p50 at 1,056 on Vera looks faster than 880. Did the machine speed up?**

**A:** No. Median got lucky while the tail got slower. Do not claim a 1,056 dip as a silicon feature.

---

## 8. Failures, Vera "2,000", and other landmines

**Q: Zero failures through 2,000?**

**A:** **Phoenix: yes** on the pinned on-node files through 2000.

**Vera: zero create fails through 1760.** Vera's ladder has no native 2000 rung. Charts/table **plot Vera 2112 as 2000** (`VERA_C2000_SOURCE = 2112` in `scripts/nvidia_brief_maxpack_charts.py`). The 2112 wave had **54 create timeouts** (~97% live, p50 67.3 s, ~22.7 /s). If he asks "was 2000 clean on Vera," say: we did not run 2000 on Vera. The point plotted as 2000 is 2112 live-almost-full, not a 0-fail 2000. Phoenix 2000 is a real 2000 with 0 fails.

Above 2112 Vera create loss grows (2464, 2784). Live-VM admission, not guest OOM. Old wall was ~710 until eng raised `RLP_MAX_LIVE_VMS`.

**Q: Vera checksum drift?**

**A:** Max-pack Vera file notes a small checksum mismatch on a few rows at some rungs (inventory: 17/5632 at 704). Vast majority match. Do not claim 100.000% checksum if he audits.

**Q: Shared box noise?**

**A:** Yes. Repeat the same rung and p50 will move. Direction (Vera higher jobs/s, usually shorter p50) is the claim, not a 10 ms delta.

---

## 9. What this workload stresses (and does not)

**Q: Is this SPECint? GEMM? Bandwidth?**

**A:** Mixed Python: process spawn, AST, search, small-file I/O, pytest. Branchy, syscall-y, cache-unfriendly. Not a sustained SVE/AVX kernel. Not STREAM. Not FFmpeg (Zen 5 wins that on other packs).

**Q: Did FP8 or SVE run?**

**A:** ISA flags are present on Vera. This agent loop is CPython + pytest. We did **not** count `perf` FP8/SVE events on this ladder. Do not attribute 22 vs 18.8 jobs/s to FP8.

**Q: Why is 9J45 slower per episode than a 9575F in other briefs?**

**A:** Different SKU tradeoff. 9J45 is the high core-count Turin we packed to 2,000 at the same 0.125/512 shape as Vera. 9575F is a smaller high-frequency box (64C/128T). At c=1, 9575F was ~tied with Vera (~7 s) while 9J45 was ~17 s. This folder's charts hide 9575. If he switches to "your other Zen 5 is as fast as Vera at idle," agree, then bring him back to **matched density on the big dual-socket**.

**Q: Core count: Vera has fewer cores. How does it win jobs/s?**

**A:** 176 vs 192 physical. Vera still ~22 /s vs ~18.8 /s when packed. The story is per-episode time staying more usable under tenancy, not "more cores." Do not say ISA wins everything. Say this agent loop plus this packing shape favors Vera on this cell vs this 9J45 cell.

---

## 10. Client / HTTP (they will ask if tput is software)

**Q: Connection pool?**

**A:** `rlp_client_tuning`: `http_max_connections` 512, wait poll 0.25 s start, factor 1.5, max 2.0 s. Same on both. On-node, so this is not the old tunnel cliff.

**Q: Could RLP software, not the CPU, cap 22 vs 18.8?**

**A:** Possible in principle (NATS, create path, netns). Against it: `duration_ms` is in-guest and still higher on 9J45 at high c (e.g. 95 s vs 67 s at the 2000/2112 points). Throughput tracks slower guests, not a 22/s software ceiling that both hit. Phoenix stays near 18.8 /s across 880–2000 while Vera stays near 22. If it were a global API cap, both would pin the same jobs/s.

---

## 11. What we did not do (say this before he does)

1. No NUMA membind / cpuset on Firecracker for this brief.
2. No SMT-off vs SMT-on.
3. No socket-0-only vs dual-socket split run on this ladder (Docker NUMA pins exist in the harness, unused here).
4. No `perf` / uncore / memory-controller trace during the 2,000 wave.
5. No matched guest kernel version.
6. No frequency lock / idle injection / isolated cpuset.
7. No RSS / `numastat` proof that 512 MiB guarantees were local DRAM.
8. No frequency lock. 9J45 `lscpu` showed 52% scaling MHz at capture time. That is not a run-long trace.
9. Vera "2000" is remapped 2112.
10. Phoenix 704 memory guarantee is 512 MiB, Vera 704 is 1 GiB.

If he wants a silicon-clean follow-up: same image, SMT on vs off, NUMA-local vs interleaved, quiet window, `perf stat` on one pinned episode plus a packed wave, guest kernel matched if they can give us a 6.12 x86 rootfs.

---

## 12. Short answers (if time is tight)

**Sockets?** Both dual-socket. Vera 88c × 2. 9J45 96c × 2. No single-socket pin.

**SMT?** On. Vera 176c/352t. 9J45 192c/384t (`0-383`).

**NUMA?** Both 2 nodes, SMT siblings in the upper CPU ids. Vera `0-87,176-263` / `88-175,264-351`. 9J45 `0-95,192-287` / `96-191,288-383`. RLP VMs **not** NUMA-pinned. Memory locality **not** proven local.

**Clocks?** Vera scaling field 100% at capture. 9J45 boost on, 1.21–4.12 GHz, scaling field 52% at a later `lscpu` (not during the 2k wave). No governor pin.

**Remote memory?** Possible. Not measured.

**Region?** Dedicated cells, `region_routing=False`, one runner each.

**vCPU?** Guest sees 1. Guarantee 0.125, burst 1.0.

**RAM?** Guarantee 1 GiB then 512 MiB. Burst 4 GiB. Disk 2 GiB.

**Client?** On-node. Not laptop, not SSH tunnel.

**Isolation?** Firecracker. Same Hub image.

**Fair?** Same seed, n, E, ladder, hold-then-exec. Asterisks: 704 memory glue, Vera 2000←2112, kernels 6.12 vs 6.8, shared cells, no NUMA policy.

**Result?** Packed agent throughput ~22 /s Vera vs ~18.8 /s 9J45, 0-fail on Phoenix through a true 2000, Vera clean through 1760.

---

## Pinned files

See [`sources.md`](sources.md). Do not quote laptop Phoenix `…012143`, pre-ARP m512 files, or Phoenix `…104841` c=880 (p50 ~26 s, superseded by glue `…125904` at 33.7 s).

---

## Appendix: 9J45 `lscpu` (oc5002, 2026-09-01)

```text
Architecture:                    x86_64
CPU(s):                          384
On-line CPU(s) list:             0-383
Vendor ID:                       AuthenticAMD
Model name:                      AMD EPYC 9J45 128-Core Processor
CPU family:                      26
Model:                           2
Thread(s) per core:              2
Core(s) per socket:              96
Socket(s):                       2
Stepping:                        1
Frequency boost:                 enabled
CPU(s) scaling MHz:              52%
CPU max MHz:                     4122.7549
CPU min MHz:                     1212.5750
Virtualization:                  AMD-V
L1d:                             9 MiB (192 instances)
L1i:                             6 MiB (192 instances)
L2:                              192 MiB (192 instances)
L3:                              1 GiB (32 instances)
NUMA node(s):                    2
NUMA node0 CPU(s):               0-95,192-287
NUMA node1 CPU(s):               96-191,288-383
```

Full flags and Spectre rows are in the SSH capture. Not repeated here.
