## Correction to my comment above: the 2.3× is not a property of the startup path

Further measurement on the same host shows that the pinned-vs-unpinned gap I posted comes from the **benchmark image's entrypoint**, not from NUMA locality of the create/clone path.

The image used for those bursts (`dtgraviet/vera-agent-benchmark:v3`) has the entrypoint `python -m workload.agent --n 30 --seed 42`. The runner releases the entrypoint gate on every clone, so every sandbox starts a CPU-bound job as soon as it is `running`. Measured on a quiet host: **1.0 full core for ~3.1 s per sandbox**. During a 1k burst, `rlp.slice/vms` holds the socket at 100% (171–183 cores busy on average across a 38 s window).

Same burst (1,000 creates, 16-process client so the client does not pace starts), interleaved, entrypoint image vs `alpine:3.20` (entrypoint exits immediately):

| image | placement | ok | p50 (s) | p95 (s) | all-ready (s) | `rlp.slice/vms` cores, mean / peak |
|---|---|---|---|---|---|---|
| agent entrypoint | pinned node 0 | 1000, 1000 | 5.5, 4.1 | 9.6, 10.0 | 10.4, 10.2 | 171 / 176 |
| agent entrypoint | unpinned | 1000, 1000 | 12.2, 5.8 | 22.3, 21.9 | 22.5, 22.0 | 183 / 350 |
| **alpine** | pinned node 0 | 1000, 999 | 2.6, 2.5 | **3.9, 3.8** | 4.0, (11.6)* | 2 / 22–27 |
| **alpine** | unpinned | 999, 1000 | 2.6, 2.0 | **4.0, 4.2** | (11.1)*, 4.2 | 3 / 34–38 |

\* One sandbox failed with `bad gateway: sandbox … not available` (see #3229), which holds all-ready open until it times out. p95 is the fair figure for those two runs.

**Revised conclusions**

- The platform's startup path brings up 1,000 sandboxes in **~4 s at p95** on one Vera host, using at most ~40 cores. **Pinned and unpinned are the same.** There is no NUMA lever for the startup path itself.
- The pinned-vs-unpinned difference only appears when the guests themselves run CPU-heavy work during the burst. Unpinned, that work spreads over both sockets and the burst gets slower, not faster. That is a placement question for **guest workloads** (vCPU thread and memory locality), which is still this issue's scope, but the evidence I posted does not show a startup-path cost.
- The "one runner per NUMA node" suggestion above is therefore **not supported** for startup. I'm withdrawing it as a startup optimization.

Apologies for the noise. The earlier table stands as data, but its attribution was wrong.
