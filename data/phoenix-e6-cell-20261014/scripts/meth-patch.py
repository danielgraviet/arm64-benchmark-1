#!/usr/bin/env python3
"""Fold the phoenix-e6 (EPYC 9J45 Turin) findings into docs/benchmark-methodology.md.

Two measured results change what the document currently tells the next operator:
  1. the one-NUMA-node rule was stated as general; it is Vera-specific and inverts on this EPYC;
  2. the single-process client artifact now has a second, independent confirmation.
Run from the root of a harness copy. Idempotent.
"""
import sys, pathlib

p = pathlib.Path("docs/benchmark-methodology.md")
if not p.is_file():
    sys.exit(f"no {p} here (run from a harness root)")
s = p.read_text()
if "phoenix-e6" in s:
    print(f"{p}: already carries the phoenix-e6 findings")
    sys.exit(0)

old_h3 = """## 3. Placement (dual-socket hosts)

- **Pinning runner + sandboxes to one NUMA node is the biggest single lever on dual-socket Vera**: 1k all-ready
  8.4–10.6 s pinned to socket 0 vs 20–23 s spread across both sockets (same host, build, settings).
- The second socket is **not** what makes it fast: everything (runner, sandboxes, API, Postgres, NATS, proxy, client)
  on the same 88-core socket gives the same all-ready time."""

new_h3 = """## 3. Placement (dual-socket hosts)

**Measure placement per platform. It is not a portable rule — the two hosts measured so far point in
opposite directions, and a pin copied from the other host costs ~50 % of the startup number.**

- **Vera (2 x 88c, 64 KiB pages):** pinning runner + sandboxes to one NUMA node is the biggest single lever.
  1k all-ready 8.4–10.6 s pinned to socket 0 vs 20–23 s spread across both sockets (same host, build, settings).
  The second socket is **not** what makes it fast: everything (runner, sandboxes, API, Postgres, NATS, proxy,
  client) on the same 88-core socket gives the same all-ready time.
- **EPYC 9J45 Turin (phoenix-e6, 2 x 96c, 4 KiB pages):** the penalty does not reproduce, and pinning is a
  **regression** once the client is not the bottleneck. 16-process client, same recipe: 1k 7.9–8.0 s whole box
  vs 11.9–12.5 s on socket 0; 2k 21.9–22.3 s vs 29.6–31.0 s. With the single-process client the two arms are
  within noise (10.2–10.8 s pinned, 10.6–11.2 s unpinned) — the client hides the difference. On this box the
  client, the control plane and the runner all want CPU, and socket 0 cannot feed all three.
- So **run both arms before publishing a placement**, and state exactly what was pinned:"""

old_rule = """Pin with `rlp.slice` + `rlp.slice/vms` `cpuset.cpus` and"""
assert old_h3 in s and old_rule in s, "methodology doc is not the expected revision"
s = s.replace(old_h3, new_h3)
s = s.replace('- So a "one socket" result must say exactly what was pinned. Pin with', '- Pin with')

old_post = """| **`post_s`** | `create_s` − `wait_s`: **not "control plane accepts the request"** | With 1,000 threads in ONE Python process it is mostly **the harness queueing on the GIL**. Measured on HQ Vera, 1k burst: 1 process → post p50 2.9–5.8 s; 16 processes → **0.23–0.50 s**, all-ready unchanged (9–12 s). |"""
new_post = """| **`post_s`** | `create_s` − `wait_s`: **not "control plane accepts the request"** | With 1,000 threads in ONE Python process it is mostly **the harness queueing on the GIL**. HQ Vera, 1k burst: 1 process → post p50 2.9–5.8 s; 16 processes → **0.23–0.50 s**, all-ready unchanged (9–12 s). Confirmed independently on phoenix-e6 (EPYC 9J45): 1 process → accept p50 4.6–4.8 s and all-ready 10.2–10.8 s; 16 processes → post p50 **0.22 s** and all-ready **7.9 s**, i.e. here the single-process client also inflates the headline number by ~30 %. |"""
if old_post in s:
    s = s.replace(old_post, new_post)
else:
    print("note: post_s row not in the expected form, left as is")

s = s.replace(
    "Learned on HQ Vera, OCI Vera, EPYC 9575F, EPYC 9755 and Vultr 9745 (Sep–Oct 2026).",
    "Learned on HQ Vera, OCI Vera, EPYC 9575F, EPYC 9755, Vultr 9745 and OCI phoenix-e6 / EPYC 9J45 Turin\n(Sep–Oct 2026).")
s = s.replace(
    "`/mnt/data/bench/FINDINGS.md` on the HQ Vera cell, and issues daytona/rlp#3212, #3213.",
    "`/mnt/data/bench/FINDINGS.md` on the HQ Vera and phoenix-e6 cells, and issues daytona/rlp#3212, #3213.")

p.write_text(s)
print(f"{p}: updated (placement rule is now per-platform; post_s has the phoenix-e6 confirmation)")
