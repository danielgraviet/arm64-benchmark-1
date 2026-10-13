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


| Step on the host          | Vera     | Zen5 (9575F) | What happens                                       |
| ------------------------- | -------- | ------------ | -------------------------------------------------- |
| Prepare sandbox disk      | 13 ms    | 143–166 ms   | Set up the sandbox's writable disk                 |
| Load saved memory         | 16–17 ms | 377–426 ms   | Restore the sandbox's saved memory                 |
| Start virtual machine     | 29–31 ms | 450–752 ms   | Start the virtual machine                          |
| Wait for guest to respond | 8–9 ms   | 226–247 ms   | Wait until the guest toolbox accepts a connection  |
| Total host startup        | 67–70 ms | 1.3–1.6 s    | Sum of the four steps above, added within each run |


Both hosts started from a prebuilt, saved sandbox state. That avoids building the state from scratch, but each new sandbox still needs host setup and a virtual machine start.

### One sandbox at a time

The numbers above are for 1,000 sandboxes started together. We also started one sandbox, deleted it, and repeated that. Three rounds of 15 on each host. The client checked every 10 ms.

The average time until the sandbox is ready is 86 ms on Vera and 67 ms on the 9575F. Each row is a separate piece of that time. The rows add up to the total. The runner steps alone, without the control plane, are 59 ms on Vera and 56 ms on the 9575F.

| Step | Vera | 9575F | What is timed |
| --- | ---: | ---: | --- |
| Control plane accepts the request | 27 ms | 11 ms | Time to take the create and queue the job |
| Prepare sandbox disk | 7 ms | 8 ms | Runner sets up the writable disk |
| Load saved memory | 8 ms | 4 ms | Runner restores the saved memory |
| Start virtual machine | 27 ms | 23 ms | Runner starts the virtual machine |
| Wait for guest to respond | 14 ms | 19 ms | Runner waits until the toolbox accepts a connection |
| Entrypoint release | 3 ms | 2 ms | Runner asks the guest to start its program |
| Time until ready | 86 ms | 67 ms | Sum of the rows above | 

**Internal note.** The runner's full clone timer is longer than the sum shown in the table: 79–83 ms on Vera and 7.2–8.9 s on Zen 5. On Zen 5, most of that difference comes from the entrypoint release.

Each sandbox has two ports. Port 2280 is the toolbox, which lets us run commands like `echo ready`. Port 2281 is the control port, which lets us finish configuring the sandbox before starting its actual startup program. Once the sandbox is configured, the runner sends a request to port 2281 to release the entrypoint.

When we're starting just a few sandboxes, both ports respond quickly. The toolbox answers, the control port accepts the entrypoint release, and the whole process takes about 80 ms. But when we start 1,000 sandboxes at once, the control port on Zen 5 becomes slow to accept connections. After the toolbox responds, the runner keeps retrying the entrypoint release until the control port accepts it. This adds a median of 4.9, 5.8, and 6.0 seconds across the Zen 5 runs.

Vera does not show the same delay. Even under the 1,000-sandbox burst, both ports continue responding quickly. The important distinction is that `echo ready` is not what gets released. It is a separate command run through the toolbox after the sandbox is running, and takes only a few tens of milliseconds. The entrypoint release is a separate step, and its retry time is not included in the table total.