## What

On arm64 (NVIDIA Vera), **about a quarter of snapshot clones wait a fixed ~580 ms** before the runner's toolbox probe gets through. On an idle host this stall dominates create latency: POST → `running` is 65 ms at p50 but **644 ms at p90**.

Three things combine:

1. **The host's first ARP request for the guest is lost.** In each per-VM netns the runner's first probe SYN to the guest triggers neighbour resolution. Recycled pool netns hold a `FAILED` entry for the guest IP: **53 of 60** sampled on an idle runner. The ARP request goes out during the restore window, 2.4–3.6 ms before the vCPU first runs, and no RX interrupt (IRQ 36, virtio-net) is ever raised for it. The kernel's own retry is `retrans_time_ms` = 1000 ms away.
2. **The daemon's resume detector never fires on arm64.** `daemon/crates/daemon/src/garp.rs:205-250` (`main` @ `d78c74689`) detects a resume by a 200 ms sleep overrunning by more than 2 s (`RESUME_JUMP`), on the premise that "the monotonic clock advances across the pause". On Vera it does not: three clones of one template reported guest uptime 1.15 s, the snapshot instant, and two different slow clones sent identical guest TCP timestamps. The `entrypoint-start` announcement cannot help either, because that POST travels the same unresolved path (the garp.rs comment already says so).
3. **What finally resolves it is the daemon's 1 s keepalive** (`garp.rs:262`). Its phase relative to the resume is frozen in the template snapshot, so every slow clone of a template waits the same time: 557–559 ms on this template, 580 ms in `toolbox_wait_ms`.

## Evidence

Cell: HQ Vera, runner from `f0611fa13`, daemon `rlp-rs-0.4.1`, stock Firecracker v1.16.1, kernel `6.17.0-1032-nvidia-64k`. The daemon resume detector, the keepalive and the runner's neighbour handling are unchanged on `main`.

- **Rate.** 200 sequential creates: 46 stalls (23%), each `toolbox_wait_ms` 579–580; the rest 1–2 ms. The agent image showed the same (586 ms). Later runs: 16/60 (27%) and 15/60 (25%).
- **Root-namespace pcap.** For a slow clone the runner's SYNs leave at 0, 211 and 422 ms (one per 200 ms dial timeout). The guest answers all three at once at ~557 ms.
- **bpftrace on the tap.** Traced `net_dev_queue` / `netif_receive_skb` on `rlptap0` plus KVM `vgic_update_irq_pending`, `kvm_vcpu_wakeup`, `kvm_wfx_arm64` and timer events; 30 sequential creates, one guest at a time.
  - Every clone, fast or slow, answers the first SYN that reaches its tap within 0.1–0.3 ms. The guest is not slow to answer TCP.
  - Before that SYN, the netns sends one ARP request to the guest. Fast clones answer it in 0.5–1 ms. **Slow clones answer the same single request 559 ms later.** It was not retransmitted.
  - In slow clones that ARP is queued to the tap before Firecracker's restore-time interrupts (IRQ 39/40, +0.42 ms) and before the vCPU's first activity (+2.7 ms). **No IRQ 36 follows it.** Later host packets (90-byte multicast) do get IRQ 36 and wake the guest, but the ARP stays unanswered.
  - At +558.2 ms the guest's virtual timer (IRQ 27) wakes the vCPU. Without any new inbound packet, the guest sends an ARP (the keepalive announcement), and the queued SYNs go through within 0.2 ms.
- **Fix-shaped A/B, no code change.** A permanent neighbour entry for the guest in every pool netns (`ip neigh replace 10.255.0.2 lladdr aa:fc:0a:ff:00:02 dev rlptap0 nud permanent`) takes stalls from **16/60 to 0/60** (max `toolbox_wait_ms` 3). Removing the entries brings it back to 15/60. The guest MAC is deterministic: `macFromIP(InnerGuestIP)`, `runner/internal/hostres/network.go:1301`, `fresh_network.go:117`.

Under a 1k burst the stall mostly disappears (p90 `toolbox_wait_ms` 11 ms), presumably because the guest is woken by other traffic first. It is an unloaded-latency problem: the single-sandbox create users actually feel.

## Options (for discussion)

1. **Runner: install a permanent neighbour entry for the guest in each netns.** It goes in when the slot is wired or bound, the same way `pinTapMAC` fixed the reverse direction, with the guest MAC the snapshot froze. This removes ARP from the resume hot path entirely, and the A/B above shows it.
2. **Daemon: make resume detection work where the monotonic clock is restored.** For example, compare `CLOCK_REALTIME` against monotonic, or use `CLOCK_BOOTTIME`. This depends on the guest wall clock actually being corrected at load, which today it is not on arm64 (#767). Or announce on any resume signal the VMM can deliver.
3. **Firecracker/runner: find why an RX frame queued to the tap during restore is never delivered.** That may be a Firecracker restore-ordering issue worth reporting upstream.

Option 1 alone is sufficient for this symptom. Option 2 also keeps working for paths that do not go through a pool netns.

## Related

- #767: snapshot clock handling. On arm64 the guest wall clock stays at template time; measured here 2 h 52 min behind on a ~3 h old template.
- #3229: the readiness gate is a bare TCP accept.
- daemon/AGENTS.md documents this tail ("on the 1 s keepalive alone, 29% of clone-resumes paid ~800 ms") and the monotonic-jump premise, which does not hold on arm64.

Found while measuring the create path step by step on NVIDIA Vera (2026-10-14). pcap, bpftrace timelines and scripts are available on request.
