# Why NVIDIA Vera Performs Differently Under Heavy Agent Workloads

## Understanding the performance beyond core count

In our initial benchmarks, NVIDIA Vera sustained up to **13.3 completed coding-agent jobs per second**, compared with approximately 11.0 on AMD EPYC 9755 and 8.0 on EPYC 9575F. Vera also brought 1,000 Daytona sandboxes online in 10.8 seconds in our original testing.

These results raised an important question: **What actually accounts for the performance differences?**

A faster CPU alone does not explain everything. Running thousands of coding agents places pressure on several parts of a system, including CPU scheduling, memory management, virtual machine restoration, and the services responsible for creating and managing sandboxes.

We conducted additional experiments to distinguish these effects. We measured CPU frequency under load, examined memory bandwidth, isolated the sandbox control plane, and broke startup into individual operations.

The results point to two distinct findings. Vera's sustained throughput is explained largely by its core count and the amount of work those cores complete under heavy load. Sandbox startup is more complicated, with meaningful differences in memory restoration and control-plane behavior that we have not fully attributed to individual hardware features.

## 1. Why Vera sustains more completed agent jobs

The first thing we wanted to understand was why throughput levels off at different rates on the three CPUs.

Our workload runs coding agents in isolated Daytona sandboxes. Each agent operates in its own environment, executing code, modifying files, and running tests. As we increase the number of concurrent sandboxes, the CPUs eventually reach a point where adding more agents no longer increases the number of jobs completed per second.

That sustained completion rate is what we call the throughput plateau.


| CPU            | Cores used for agent work | Sustained throughput |
| -------------- | ------------------------- | -------------------- |
| NVIDIA Vera    | 88                        | 12.7–13.3 jobs/s     |
| AMD EPYC 9755  | 128                       | ~11.0 jobs/s         |
| AMD EPYC 9575F | 64                        | ~8.0 jobs/s          |


An important observation is that Vera completes more jobs per second than the 128-core EPYC 9755, despite using fewer cores for the agent workload.

To investigate this, we looked at how long each job occupied a core under full load.

Our measurements produced the following approximate relationship:

**Throughput = available cores ÷ core-seconds consumed per job**


| CPU        | Core-seconds per job at full load | Predicted throughput |
| ---------- | --------------------------------- | -------------------- |
| Vera       | 6.93                              | 12.7 jobs/s          |
| EPYC 9755  | 11.6                              | 11.0 jobs/s          |
| EPYC 9575F | 8.08                              | 7.9 jobs/s           |


These calculations closely match the observed results. They also help explain why core count alone is insufficient. What matters is how many cores are available and how quickly each core completes useful work when the machine is fully occupied.

### CPU frequency explains part of the difference

We measured CPU frequency at light load and again when the machines were running large numbers of agents.


| CPU         | Light load | Full load | Frequency change |
| ----------- | ---------- | --------- | ---------------- |
| NVIDIA Vera | 3.16 GHz   | 2.96 GHz  | −6%              |
| EPYC 9575F  | 4.73 GHz   | 3.60 GHz  | −24%             |


The EPYC 9575F runs at a much higher clock frequency when lightly loaded, but that frequency falls substantially when all cores are active.

Vera operates closer to its light-load frequency even when the machine is heavily utilized.

This distinction is important for agent workloads. A single coding agent might occupy only a small portion of a CPU, but thousands of concurrent agents can keep nearly every core busy for extended periods. Performance under those conditions depends much more on sustained execution than on the highest frequency a processor can reach briefly.

In our measurements, a fully loaded Vera core completed approximately **16% more work per second** than a fully loaded EPYC 9575F core on this workload.

The frequency measurements help explain that result. However, clock speed is not a direct measurement of instructions completed or architectural efficiency. Different processors can perform different amounts of work per clock cycle.

We therefore interpret Vera's advantage as a combination of its sustained operating frequency and its measured per-core completion rate, rather than attributing the entire difference to clock speed.

We have not yet established precisely how much of the frequency difference comes from power limits, thermal behavior, or processor-specific frequency management.

## 2. Why memory bandwidth does not explain the throughput advantage

Vera also has an unusually capable memory system. That makes memory bandwidth a natural candidate for explaining its performance.

However, our measurements do not indicate that memory bandwidth is the limiting factor for this particular workload.

On the EPYC 9575F, we measured approximately **33 GB/s of DRAM bandwidth** at the throughput plateau. This represents less than 10% of the theoretical bandwidth available from its 12 DDR5 memory channels.

We also measured a memory-stall share of approximately 10.7% at full load. That share was lower than at light load, rather than increasing as concurrency increased.

For Vera, our estimated traffic was approximately 55 GB/s against a theoretical memory bandwidth of roughly 1,075 GB/s.

Taken together, the evidence suggests that neither machine is approaching a sustained DRAM bandwidth limit.

This matters because it changes how we interpret Vera's advantage. The memory subsystem may still affect latency, caching, and individual operations, but we do not have evidence that higher aggregate memory bandwidth is responsible for the observed throughput plateau.

Instead, the results remain consistent with CPU execution capacity under sustained load.

We also tested whether disk allocation influenced throughput on the EPYC 9575F. Changing the sandbox disk allocation from 128 MiB to 1 GiB produced nearly identical results: 7.84 versus 7.92 jobs per second.

Disk allocation therefore did not meaningfully explain the sustained throughput difference either.

## 3. Separating CPU performance from the Daytona control plane

Every Daytona sandbox depends on services outside the guest environment.

The control plane accepts requests, coordinates sandbox creation, and communicates with the runner responsible for managing the virtual machines.

It is reasonable to ask whether differences in these services, rather than CPU performance, could account for Vera's higher throughput.

We compared the time observed by the client with the time spent executing the actual job inside the sandbox.

Across the three systems, the difference accounted for only **0.5–0.6% of total job time** across the tested concurrency levels.

This tells us that the sustained throughput plateau is overwhelmingly determined by work executed inside the guest environments, rather than the request path surrounding them.

We also investigated whether Vera benefited from having a second CPU socket available to run the control plane.

On both Vera hosts, the sandboxes and their runner were assigned to one socket for the relevant tests, while both physical sockets remained online. In additional testing on OCI Vera, restricting the workload to socket 0 reproduced a throughput of 12.69 jobs per second, consistent with the original 12.7–13.3 range.

This supports interpreting the throughput result as the performance of **88 Vera cores serving the agent workload**, rather than attributing the difference to the additional cores available on the second socket.

The distinction becomes more important during startup, where the control plane plays a substantially larger role.

## 4. Why starting thousands of sandboxes is a different problem

Sustained throughput measures how quickly a running fleet completes useful work. Startup measures how quickly the platform can create that fleet in the first place.

These workloads stress the machine in different ways.

During startup, Daytona must prepare sandbox storage, restore saved memory state, configure each environment, and release its startup process. The control plane must coordinate those operations across hundreds or thousands of sandboxes.

Our original Vera result showed 1,000 sandboxes becoming ready in 10.8 seconds. To better understand that result, we repeated startup experiments on another Vera system (OCI) and a clean EPYC 9575F host.

The investigation revealed two important differences.

### Memory restoration is considerably faster on Vera

During a 1,000-sandbox startup burst, we measured the time spent in two host-side preparation steps.


| Startup operation    | OCI Vera | Clean EPYC 9575F |
| -------------------- | -------- | ---------------- |
| Prepare sandbox disk | 13 ms    | 48–68 ms         |
| Load saved memory    | 16–17 ms | 110–332 ms       |


These are per-sandbox host-step measurements, not the total time required to start the fleet.

Vera completed the measured memory restoration step approximately 7–20 times faster than the EPYC 9575F.

That difference is significant, especially when the platform must perform the same operation for thousands of sandboxes.

However, we cannot yet attribute it to a single mechanism. One particularly interesting candidate is the host operating system's memory page size.

### How 64 KiB memory pages may help

The Vera systems in our testing use Linux kernels configured with 64 KiB memory pages. The EPYC systems use 4 KiB host pages.

A memory page is the unit the operating system uses to map virtual memory to physical memory.

For example, mapping 1 MiB of memory requires 256 pages with a 4 KiB page size, but only 16 pages with a 64 KiB page size.

That is a 16-fold difference in the number of page mappings.

When a sandbox is restored from a snapshot, its saved memory can be mapped into the host address space and populated as pages are accessed. Larger host pages can reduce the number of page-table entries and page faults needed to populate the same amount of memory, although the actual benefit depends on the restoration implementation and access pattern.

This makes page size a plausible contributor to Vera's faster memory-restoration step.

It is also consistent with the observed 7–20× difference. Vera and EPYC differ in their memory systems, page-fault handling, and processor architecture and those differences could also contribute.

For now, the technically supported conclusion is that **Vera restores snapshot memory considerably faster in this test, and its larger host pages are one plausible contributor**.

Page size is much less likely to explain the sustained throughput difference. Our guests use 4 KiB pages on all platforms, and the throughput workload largely operates on resident memory rather than repeatedly restoring snapshots.

Larger host pages also reduce the amount of page-table metadata required to manage a large fleet. We estimate a saving of roughly 20 GB in our configuration, but memory capacity was not the limiting factor at the densities tested.

## 5. What we learned about startup overhead

The startup experiments also uncovered differences unrelated to memory restoration.

On the EPYC 9575F, a background CPU-intensive process was running during some earlier measurements. Stopping that process reduced the median time for a 1,000-sandbox burst from 18.6 seconds to 9.7 seconds in the affected measurement.

The process also contributed to delays in the runner's entrypoint-release operation, which tells each prepared sandbox to begin executing its startup program.

After removing the background load, that operation still added approximately 1.3–2.1 seconds during a 1,000-sandbox burst on the EPYC host. On OCI Vera, the corresponding delay was negligible in the measured runs.

The clean EPYC measurements therefore still reveal a real difference in startup behavior, but they also show why controlling background CPU activity is necessary before comparing systems.

We separately measured how much CPU capacity the EPYC control plane needed during a burst. Giving the API, database, and NATS services dedicated cores reduced the time to accept 1,000 requests from approximately 7.7 seconds to 2.6 seconds.

However, that change also left fewer cores for the sandbox runner, slowing other parts of the startup process.

This experiment illustrates an important distinction between startup and sustained throughput.

During sustained operation, almost all measured time is spent executing work inside the guest. During startup, multiple host-level services compete for CPU time, and improving one stage can shift contention to another.

We also isolated the underlying Firecracker restoration operation in a test without Daytona. On Vera, that study achieved approximately 4,000 restores per second, equivalent to roughly 0.25 seconds for 1,000 restores at that rate.

This indicates that the virtual machine restoration mechanism itself accounts for only a small fraction of the full fleet startup time. Most of the measured startup latency comes from the surrounding platform work.

## 6. What the experiments tell us

Our additional testing provides a clearer picture of where Vera's performance advantage comes from and where further investigation is needed.

For sustained coding-agent workloads, the evidence is comparatively strong. Vera combines 88 available cores with a high per-core completion rate under full load. Its measured frequency decreases only modestly as concurrency increases, and our tests do not show DRAM bandwidth, disk allocation, or Daytona's control plane becoming the dominant throughput bottleneck.

The startup story is less settled.

Vera's measured disk preparation and snapshot memory restoration are substantially faster than the corresponding operations on the EPYC 9575F. Larger host memory pages may contribute to memory restoration performance, but we have not isolated their effect. Control-plane scheduling and runner coordination also play a meaningful role during large bursts.

The most important lesson is that **performance at thousands of concurrent agents depends on more than the speed of an individual core**.

For sustained workloads, it depends on how much useful computation the cores can deliver together. For startup, it depends on how efficiently the operating system, memory manager, virtual machine runtime, and control plane can prepare thousands of environments simultaneously.

Our measurements show that Vera performs particularly well under sustained CPU pressure. They also identify specific startup operations where the platform is faster, while leaving room for the controlled experiments needed to explain those differences completely.