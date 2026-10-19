# Where the 1k sandbox creation time goes

Three runs per host, 1,000 sandboxes per run. All 1,000 sandboxes became ready in every run. Vera is the OCI host; Zen5 is the EPYC 9575F host.

For each run, we measured the median across 1,000 requests. The ranges below show the lowest and highest of the three run medians. Percentages show each phase's share of the sandbox-ready median in the same run. Earlier requests are usually faster; later requests take longer as the batch progresses.

### Request to sandbox ready


| Phase             | Vera                   | Zen5 (9575F)           | What is timed                                                 |
| ----------------- | ---------------------- | ---------------------- | ------------------------------------------------------------- |
| Create request    | 5.2–5.9 s (56.5–61.7%) | 7.1–7.8 s (44.0–46.9%) | Median `post_s`, the control-plane part of the create request |
| Wait for a runner | 3.5–3.9 s (36.8–41.9%) | 8.7–9.2 s (51.6–53.6%) | Median `wait_s`, waiting for a runner                         |
| Sandbox ready     | 9.2–9.6 s (100%)       | 16.2–17.8 s (100%)     | Median `create_s`, from request through ready                 |
| All 1,000 ready   | 18.7–19.1 s            | 30.6–35.0 s            | Total batch wall time                                         |




### What the host does to start each sandbox


| Step on the host          | Vera     | Zen5 (9575F) | What happens                                      |
| ------------------------- | -------- | ------------ | ------------------------------------------------- |
| Prepare sandbox disk      | 13 ms    | 143–166 ms   | Set up the sandbox's writable disk                |
| Load saved memory         | 16–17 ms | 377–426 ms   | Restore the sandbox's saved memory                |
| Start virtual machine     | 29–31 ms | 450–752 ms   | Start the virtual machine                         |
| Wait for guest to respond | 8–9 ms   | 226–247 ms   | Wait until the guest toolbox accepts a connection |
| Total host startup        | 67–70 ms | 1.3–1.6 s    | Time for the runner to start the sandbox          |

### Ten at a time, and one hundred at a time

Ten sandboxes start together, and one hundred start together. We time each one until it is ready, then take the average.

The first table is that average. The control plane plus the wait for the runner add to it. The second table is the runner's own clock for the same sandboxes. Disk, memory, the virtual machine, the toolbox, and the remaining runner time add to the runner time. That clock overlaps the wait, so it keeps its own total.

| Ten at a time | Vera | 9575F |
| --- | ---: | ---: |
| Control plane accepts the request | 49 ms | 20 ms |
| Wait for the runner | 67 ms | 84 ms |
| Average time until ready | 116 ms | 104 ms |

| Ten at a time, on the runner | Vera | 9575F |
| --- | ---: | ---: |
| Prepare sandbox disk | 8 ms | 39 ms |
| Load saved memory | 8 ms | 6 ms |
| Start virtual machine | 30 ms | 8 ms |
| Wait for guest to respond | 7 ms | 19 ms |
| Other runner time | 6 ms | 16 ms |
| Runner time | 59 ms | 88 ms |

| One hundred at a time | Vera | 9575F |
| --- | ---: | ---: |
| Control plane accepts the request | 523 ms | 259 ms |
| Wait for the runner | 120 ms | 457 ms |
| Average time until ready | 643 ms | 716 ms |

| One hundred at a time, on the runner | Vera | 9575F |
| --- | ---: | ---: |
| Prepare sandbox disk | 8 ms | 63 ms |
| Load saved memory | 8 ms | 178 ms |
| Start virtual machine | 24 ms | 7 ms |
| Wait for guest to respond | 7 ms | 197 ms |
| Other runner time | 6 ms | 5 ms |
| Runner time | 53 ms | 450 ms |

At 10, the average time until ready is 116 ms on Vera and 104 ms on the 9575F.

At 100, the average time until ready is 643 ms on Vera and 716 ms on the 9575F. The 9575F runner at 100 is 450 ms, because loading memory and the toolbox wait both stretched. 

**Internal note.** The runner's full clone timer is longer than the sum shown in the table: 79–83 ms on Vera and 7.2–8.9 s on Zen 5. On Zen 5, most of that difference comes from the entrypoint release.

Each sandbox has two ports. Port 2280 is the toolbox, which lets us run commands like `echo ready`. Port 2281 is the control port, which lets us finish configuring the sandbox before starting its actual startup program. Once the sandbox is configured, the runner sends a request to port 2281 to release the entrypoint.

When we're starting just a few sandboxes, both ports respond quickly. The toolbox answers, the control port accepts the entrypoint release, and the whole process takes about 80 ms. But when we start 1,000 sandboxes at once, the control port on Zen 5 becomes slow to accept connections. After the toolbox responds, the runner keeps retrying the entrypoint release until the control port accepts it. This adds a median of 4.9, 5.8, and 6.0 seconds across the Zen 5 runs.

Vera does not show the same delay. Even under the 1,000-sandbox burst, both ports continue responding quickly. The important distinction is that `echo ready` is not what gets released. It is a separate command run through the toolbox after the sandbox is running, and takes only a few tens of milliseconds. The entrypoint release is a separate step, and its retry time is not included in the table total.