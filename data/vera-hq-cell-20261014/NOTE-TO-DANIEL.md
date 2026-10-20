Hi Daniel, a summary of what we found on HQ Vera and the 9575F (Oct 13–14), and what it changes in the numbers.

**1. The startup benchmark has been measuring the image's entrypoint, not startup.** `vera-agent-benchmark:v3` boots into `python -m workload.agent --n 30 --seed 42`, and the runner starts that entrypoint in every sandbox. So each of the 1,000 sandboxes in a create-ready burst runs ~3 core-seconds of real work as soon as it's up, and the host sits at 100% for 30+ s. The same 1k burst with `alpine:3.20` (entrypoint exits immediately):
- HQ Vera: ~4.0 s all-ready, p95 3.8–4.2 s, pinned or unpinned.
- 9575F: ~4.0 s all-ready, p95 3.9 s.
- With the agent image: Vera one socket ~10 s, 9575F 24–31 s.

**The platform's startup path is the same on both machines.** The Vera advantage in our startup charts is CPU throughput on the entrypoint workload. Startup charts need rerunning with an idle image (`MPFLEET_IMAGE=alpine:3.20 mpfleet.py --procs 16`), or relabeling as "startup under load".

**2. "Control plane accepts the request" (`post_s`) is the client, not the API.** With 1,000 threads in one Python process, most of `post_s` is client queueing. From 16 processes, accept p50 is 0.23–0.50 s instead of 2.9–5.8 s, and all-ready doesn't change.

**3. Throughput on HQ Vera: 26.6 jobs/s with both sockets, 13 on one.** The published 13.3 was a one-socket run (`rlp.slice` pinned to socket 0). Pinning matters only while guests do CPU work. I had told people it was a NUMA effect on startup; it isn't, and I've corrected that on daytona/rlp#391.

**4. The Vera tuning package had no measurable effect.** Event audit off, quiet progress, API restarts, `cpuidle.off`/`init_on_alloc=0`, proxy scaling, `RLP_VM_MAXACK`, KVM `halt_poll_ns`: all identical within noise. The SMT Firecracker fork does nothing for 1-vCPU guests, and 2-vCPU clones oops on Vera with stock and fork FC (daytona/rlp#3213; not fixed by `RLP_MIGRATABLE=0`).

**5. The 9575F's published startup numbers were also inflated** by `rlp-cpu-weight-floor.sh`, which was running during the Oct 2 2k runs and the Oct 12 tables. It's stopped now; its command line is in `/root/floor-cmdline.txt`. Also: the published 2000 mean of 114.66 s keeps a 151 s outlier and drops a 96 s run, the 9755 88.4 s drops the first run (all four average 91.1 s), and Vera's 2000 throughput point had 53 failures.

**6. Box hygiene.** Both our agents operated HQ Vera at the same time, 01:06–05:57 UTC on Oct 14, so runs from that window are mixed. Your drop-ins, runner swap and `udev.conf` edit are saved in `/etc/rlp/daniel-backup-20261014_063749/`, and every host change since is in `/etc/rlp/HOSTCHANGES`. Please check `tmux ls` / `w` before starting, and ping me first. I'll do the same. Also: 9575F `/etc/hosts` was missing the hostname (fixed), and `/etc/rlp/bench-api-key` there is stale (401). The `.env` key works.

**7. Harness PR:** danielgraviet/arm64-benchmark-1#1 adds `docs/benchmark-methodology.md`, an `AGENTS.md` section your Codex will read, `scripts/host/bench-preflight.sh` (run before every rep) and `mpfleet.py` (with an `MPFLEET_IMAGE` override). The same files are installed, uncommitted, in the Vera and 9575F checkouts. Your Vera checkout has local commits up to `9fe41bc` that aren't on GitHub, so please push them.

**8. Platform issues filed:** #3212 (3 s FC socket wait), #3213 (2-vCPU clones), #3229 (a sandbox is marked running after a bare TCP accept, so hung guests look healthy).

**9. Per-step create path on HQ Vera, and four fixes.** I timed every step of a sandbox create (details in `CREATE-PATH-STEPS.md`):
- Unloaded, a sandbox is usable in ~88 ms. About 25% of creates used to stall a fixed ~580 ms on an ARP race at resume (#3265).
- A 1k burst was bound by a per-clone 16 MiB fsync (#3260), serialized cgroup creation (#3261) and the API's 128-entry accept queue (#3269).

I patched all four on HQ Vera and re-measured. **1k burst p50 dropped from 1.93 s to 1.05 s, and unloaded p99 from 658 ms to 73 ms.**

**HQ Vera now runs those patched binaries with every fix switched off**, which behaves exactly like stock (four control runs confirm it). The stock binaries are kept as `*.bak-prepatch`. If you benchmark there, say which flags were on. To turn the fixes on: `RLP_INITDISK_MODE=nofsync`, `RLP_CGROUP_POOL=1400`, `RLP_NEIGH_PERMANENT=1` in `runner.env`, and `RLP_API_LISTEN_BACKLOG=4096` in `api.env`.

**10. One more benchmark trap: fresh connections.** If every client thread opens a new connection at burst start, about half of a 1k burst waits ~1 s on TCP retries before the API even sees the request. That's the 128 backlog again. Report it, or warm the connections first.

**11. Update: the fixes are now ON at HQ Vera, and that is the new reference.** They're set in `20-create-path-fixes.conf` drop-ins, separate from `runner.env`/`api.env`. Compare new results against `BASELINE-VERA-FIXES-20261014.md`.

Preflight now prints `create_path_fixes ON|OFF|PARTIAL`, so every result is labelled.

With the fixes on, a 1k idle-image burst takes create p50 1.5–1.6 s and p95 2.5–2.6 s, against 2.1–2.4 s and 3.3–3.8 s with them off. Agent-image startup and throughput are unchanged. Don't compare these numbers with the EPYC hosts, which still run stock binaries.

I also set a 120 s client read timeout (`RLP_HTTP_READ_TIMEOUT_S`). Without it, a single wedged guest hangs a whole ladder.

**12. The 9575F now runs the same build as HQ Vera, with the fixes ON.** Same commit and same patches, built for x86. The old binaries are kept as `/usr/local/bin/rlp-{runner,api}.bak-prepatch`. Compare against `BASELINE-EPYC9575-FIXES-20261014.md`, which has the side-by-side with Vera.

Headline: with the fixes on, **the 9575F starts sandboxes faster than Vera** (1k idle-image create p50 1.06 s vs 1.57 s, p95 1.59 s vs 2.57 s). Vera keeps a ~3.3× throughput lead (26.7 vs 8.0 jobs/s).

If you run level-704 ladders on the 9575F, set `RLP_HTTP_READ_TIMEOUT_S=600`. Episodes there take 83 s at p50, and a 120 s timeout cuts off healthy ones.
