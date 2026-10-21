# Network test: Paperspace (DigitalOcean) ATL1 nodes, 2026-10-20

Five bare-metal nodes in Paperspace's ATL1 datacenter (a DigitalOcean company): `atl1node853` (the rlp cell), `864`,
`861`, `865`, `857`. Tested between the nodes, from the nodes to the internet, and from inside sandboxes on the 853
cell. Raw data and scripts are in this directory. `do2001` (<do2001-host>, the other DigitalOcean host) refused SSH
and was not tested.

Host public IPs are replaced with placeholders (`<node853-public>` … `<node857-public>`, `<do2001-host>`), as in
the rest of this directory; private `10.46.90.x` addresses are kept.

## Summary

| | result |
|---|---|
| node ↔ node latency | ping avg **11–15 µs**; TCP request/response p50 **13–15 µs**, p99 17–21 µs on 18 of 20 pairs |
| node → node, 1 TCP flow | **34–40 Gb/s** |
| node → node, 64 flows | **369–376 Gb/s**, which is TCP line rate for 2 × 200 GbE at MTU 1500 |
| two disjoint pairs at once | 376 + 372 Gb/s: neither pair slows the other |
| node → internet | ≥ **10 Gb/s per node** and ≥ **33 Gb/s** for the five nodes together. Every result was capped by the remote test servers, so the real uplink limit is higher and unknown. |
| internet latency | Atlanta 0.7–1.4 ms, Ashburn 26 ms, New York 23 ms, Fremont 52 ms, France 94 ms, Germany 114 ms |
| inside a sandbox (1 vCPU) | 1 flow **40 Gb/s out / 21 Gb/s in**; 64 sandboxes at once **375 / 376 Gb/s** (line rate) |
| **sandbox internet access** | **none on this cell**: sandbox egress leaves with a private source address. Filed as **daytona/rlp#3516**. The numbers above used a temporary host-side workaround. |

## Hosts

| | |
|---|---|
| hardware | HPE ProLiant DL325 Gen11, 1 × EPYC 9555P, `atl1nodeNNN.mgmt.atl1.paperspace.com` |
| NIC | 2 × 200 GbE Mellanox (`mlx5_core`) in an LACP bond (`bond0`, 802.3ad, hash `encap3+4`, 63 queues). One flow uses one link (≤ 200 Gb/s); many flows can use both (400 Gb/s). |
| addresses | private `10.46.90.70–74/24` on `bond0`; public `<node853…857-public>` as a routed `/32` on `lo`, with policy routing (`/etc/netplan/99-policy-routing.yaml`). There is no global IPv6, only link-local. |
| software | Ubuntu 24.04.5, kernel 6.8.0-139. Stock network settings: MTU 1500, `cubic`, `fq_codel`, `tcp_rmem` max 6 MB, `rmem_max` 208 KB. CPU governor `performance`. |
| tools | `iperf3` 3.16 and `netperf` 2.7.0, installed from apt on all five nodes and left installed. Their daemons are stopped. Every change is logged in `/etc/rlp/HOSTCHANGES` (853) or `/root/HOSTCHANGES` (the others). |

## 1. Between the nodes (`net-nodes.sh`)

**Latency, all 20 directed pairs** (ping: 1,000 × 10 ms; netperf `TCP_RR`, 1-byte request/response, 10 s)

| | range over the 20 pairs |
|---|---|
| ping avg | 11–15 µs (max 41–148 µs) |
| TCP_RR p50 | 13–15 µs |
| TCP_RR p99 | 17–21 µs on 18 pairs; 58 µs on 857→864 and 90 µs on 865→857 (single runs, not repeated) |
| transactions/s | 57,000–76,000 |

All five nodes are probably on the same switch.

**Throughput** (iperf3, 15 s with the first 2 s omitted, receiver side; 64 flows = 16 processes × 4)

| path | 1 flow | 8 flows | 64 flows |
|---|---|---|---|
| 864 → 861, private | 34.3 Gb/s | 280.0 | **374.0** |
| 861 → 864, private | 37.1 | 276.2 | **368.7** |
| 864 → 861, public address | 39.8 | — | **374.0** |
| 861 → 864, public address | 40.5 | — | **375.9** |
| full mesh, 20 pairs, private | — | 216–314 (median 273) | — |
| two pairs at once (864→861, 865→857) | — | — | **376.4 + 371.7** |

- **Line rate.** TCP at MTU 1500 carries at most 1,448 bytes of payload per 1,538 bytes on the wire, so 400 Gb/s gives
  376.6 Gb/s. 64 flows reach it in both directions, and two pairs reach it at the same time, so this part of the fabric
  doesn't block.
- **One flow is limited by one CPU core, at 34–40 Gb/s.** Eight flows in one iperf3 process (216–314 Gb/s) vary with
  how the hash spreads them over the two links.
- **Public addresses** go through one extra hop, the provider's gateway, which doesn't answer mtr. Ping rises from
  12 µs to 45 µs; throughput doesn't change.

## 2. To the internet (`net-inet.sh`, `net-inet2.sh`)

Every node leaves the network with its own public address (Cloudflare reports `colo=ATL`).

**Latency (ping × 50; the five nodes agree within ~2 ms)**

| destination | RTT |
|---|---|
| Cloudflare 1.1.1.1 / Google 8.8.8.8 | 0.67–0.93 ms |
| Clouvider Atlanta, Vultr Atlanta | 0.7–1.4 ms |
| Clouvider New York / Ashburn | 22–24 / 25–26 ms |
| Hurricane Electric, Fremont (`iperf.he.net`) | 51.6 ms |
| Hetzner Hillsboro, Oregon | 86.8 ms |
| OVH, Roubaix, France | 92–96 ms |
| Hetzner Falkenstein, Germany | 114–115 ms |

**Download and upload, per node**

| test | range over the 5 nodes |
|---|---|
| HTTP, 1 stream: Vultr Atlanta / Linode Atlanta / Linode Newark | 2.9–3.6 / 1.1–1.2 / 1.0–1.2 Gb/s |
| HTTP, 1 stream: Hetzner Ashburn / Hillsboro / Falkenstein / OVH France | 1.0–1.6 / 0.33 / 0.25 / 0.33 Gb/s |
| HTTP, 16 streams: Linode Atlanta / Hetzner Ashburn | 6.6–8.2 / 2.6–3.5 Gb/s |
| HTTP, 4 servers × 8 streams at once | **9.3–10.4 Gb/s** (lower bound, see below) |
| iperf3, Clouvider Atlanta, download, 1 / 8 streams | 3.4–4.1 / 4.5–8.3 Gb/s |
| iperf3, Clouvider Atlanta, upload, 1 / 8 streams | 5.8–7.8 / 6.2–8.6 Gb/s |
| HTTP upload to Cloudflare, 1 / 8 × 100 MB | 0.6–1.0 / 1.7–5.0 Gb/s |
| **all 5 nodes at once**, 4 servers × 8 streams each | 5.7–7.8 Gb/s each, **33.4 Gb/s total** |

**What limits these numbers is the remote servers, not the nodes:**
- Linode's 1 GB files finished inside the 20 s window (8 × 1,049 MB / 20 s = exactly 3.36 Gb/s), so the 4-server
  figure is a lower bound.
- Vultr served one connection per client (0.42 Gb/s = one file in 20 s).
- With all five nodes pulling at once, the shared servers ran out: Linode Atlanta totalled ~9 Gb/s across the five
  nodes, Linode Newark ~9 Gb/s, and Clouvider Atlanta ~8.3 Gb/s. Each behaves like a 10 GbE server.
- Cloudflare refused large download requests (HTTP 403 at both 1 GB and 100 MB).

Measuring the real uplink limit needs an iperf3 server with 100 GbE or more that we control, outside this datacenter.

**Single long-distance streams are capped by the default TCP buffers.** Speed × RTT gives a ~3–3.5 MB window every
time (OVH 0.33 Gb/s × 94 ms, Hetzner Falkenstein 0.26 × 114 ms, Hillsboro 0.33 × 87 ms), which is what the 6 MB
`tcp_rmem` maximum allows. An A/B on 864 with the maximum raised to 64 MB, then reverted:

| single stream | stock (6 MB) | 64 MB |
|---|---|---|
| OVH France | 0.33 Gb/s | **0.64** |
| Hetzner Falkenstein | 0.26 | 0.26 |
| Hetzner Hillsboro | 0.33 | 0.34 |
| Hetzner Ashburn | 1.06 | 1.03 |

OVH doubled. Hetzner didn't change, so Hetzner limits each connection on its side. For long single transfers from
these hosts, such as pulling large images from Europe, raising `tcp_rmem` helps when the far server allows it.

## 3. Inside sandboxes on the 853 cell (`sbnet.py`)

Alpine 3.20 sandboxes with 1 vCPU and 1 GiB; this cell allows at most 1 vCPU (`RLP_BURST_MAX_CPU=1`). iperf3 inside
the guest sends to node 864. The path is guest virtio-net → tap → 1:1 NAT inside the sandbox's network namespace →
veth → host masquerade → `bond0`. Guest MTU 1500. No bandwidth limit applies anywhere on this path.

**Sandboxes on this cell have no internet access** (daytona/rlp#3516):
- The runner masquerades sandbox traffic to `bond0`'s primary address, the private `10.46.90.70`.
- The provider only routes the public `/32` that sits on `lo` (`<node853-public>`) to the internet.
- So DNS, ping, HTTP and `apk` all time out inside a sandbox, while the private LAN works. A capture on `bond0`
  showed requests to 1.1.1.1 leaving with source `10.46.90.70` and no reply.
- The benchmark workloads never need the internet, which is how this went unnoticed.
- Current `main` has the same masquerade rule. It also denies RFC1918 destinations (#2333), so on `main` a sandbox on
  these hosts would reach nothing outside the runner.

For this measurement only, a temporary nft table (`snat-on.sh`) rewrote non-private sandbox traffic to
`<node853-public>` ahead of the runner's masquerade. Sandbox egress then worked (`ip=<node853-public> colo=ATL`).
**The table was removed afterwards, so the cell is back to stock: no internet from sandboxes.**

| test (1 vCPU sandbox) | result |
|---|---|
| ping 10.46.90.71 (node 864) / 1.1.1.1 | avg 59 µs / 0.70 ms (the host alone: 12 µs / 0.67–0.93 ms) |
| → 864 private, 1 flow, sandbox→node / node→sandbox | **40.6 / 21.2 Gb/s** |
| → 864 private, 4 flows | 60.5 / 33.1 Gb/s |
| → 864 public address, 1 flow / 4 flows | 37.9 / 57.5 out, 22.2 / 29.8 in |
| → Clouvider Atlanta (internet), 1 / 8 flows, upload | 8.4 / 8.7 Gb/s |
| ← Clouvider Atlanta, 1 / 8 flows, download | 3.8 / 5.1 Gb/s |
| HTTP download, Linode Atlanta 1 GB | 1.17 Gb/s |

| many sandboxes at once, 1 flow each to its own port on 864 | total | per sandbox |
|---|---|---|
| 16 sandboxes, sandbox→node / node→sandbox | 356.9 / 324.5 Gb/s | 11.6–27.8 / 16.8–23.7 |
| 64 sandboxes, sandbox→node / node→sandbox | **375.0 / 376.2 Gb/s** | 3.1–7.9 / 2.4–7.7 |

- **One 1-vCPU sandbox sends at the same rate as the host's single flow** (~40 Gb/s). Receiving is about half that
  (21 Gb/s), because the one vCPU also has to process incoming packets in the guest.
- **64 sandboxes fill the 400G bond in both directions.** The NAT and conntrack layers don't limit aggregate
  throughput at this scale.
- **Going through the guest adds ~45 µs to ping** (59 µs vs 12 µs host to host).
- Internet throughput from a sandbox matches the host's, because the remote servers set the limit in both cases.

## Caveats

- One run per configuration. The mesh and latency numbers are consistent, but the two p99 outliers weren't repeated.
- A short 2-second iperf3 probe from 864 to the internet overlapped the mesh latency step (pairs without 864) at about
  09:47 UTC.
- The internet figures are lower bounds set by public test servers, from one datacenter, on one day.
- Sandbox numbers come from the bench build (`f0611fa13`). It predates #2333, so on `main` the sandbox → private-LAN
  path (10.46.90.x) would be denied; the public-address path is the one that matters there.
- Only 1-vCPU sandboxes were tested, because the cell's config allows no more.
