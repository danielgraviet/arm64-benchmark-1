# Vera vs EPYC 9575F vs EPYC 9755 for packed agent sandboxes

September 2026  
Daytona · one-socket compare

Daytona runs coding agents inside isolated sandboxes. Production nodes pack many of those sandboxes on one machine. The questions for us are simple:

1. How many agent jobs per second does the chip still deliver when the node is full.
2. How fast can we stand up a dense fleet when we need to.

We matched the same agent workload on a single Vera socket, a Zen 5 9575F box, and a Zen 5 9755 box, packing from 44 sandboxes through 2000. The job is `n=45`: eight episodes per sandbox, building a small broken Python package, searching and parsing it, applying a patch, then running pytest. That is the same loop agents use on Daytona: search, apply, test, repeat.

## How we measured

Same agent image, same `n=45` coding loop, eight episodes per sandbox, hold-then-exec so create is not in the throughput number. Vera's host has two 88-core sockets. We pinned the Daytona runner and every sandbox to socket 0 so this is a single socket comparison. 9575F is 64 cores at high clocks. 9755 is 128 cores at lower clocks. Same client knobs on create-ready where we compare them.

## Throughput 44–2000: cores help once packed, clocks still matter

Vera's peak agent throughput is 13.3 jobs/s at 352 concurrent sandboxes. 9755 peaks at 11.1 jobs/s (about 1.4× the 9575F peak of 8.3). Vera stays about 1.2× 9755 at that packed plateau.

Once packed, the order holds. 9575F flattens near 8 jobs/s after 176. 9755 sits near 11 jobs/s through 2000. Vera sits near 13. At 2000 concurrent sandboxes the line is Vera 12.7, 9755 10.9, 9575F 8.1.

![Agent throughput vs concurrency, three-way](../graphs/throughput_3way_44_2000.png)

![Peak packed agent throughput](../graphs/peak_throughput_3way.png)

![Agent throughput at 2000 concurrent sandboxes](../graphs/throughput_at_2000_3way.png)

## Median duration: jobs get slower, the gap tracks throughput

p50 duration climbs with concurrency on all three. Throughput stays flat because each job takes longer under load. At 2000, Vera's p50 is 143s, 9755 is 177s, 9575F is 237s. The duration ratio tracks the throughput ratio once the node is full.

![Agent p50 duration vs concurrency, three-way](../graphs/p50_duration_3way_44_2000.png)

## Create ~1000 sandboxes: cold start prefers clocks

This is not a full customer agent workload. It is a create-and-ready check: boot the agent image, run `echo ready`, and measure how long until that command succeeds across a thousand sandboxes in parallel. That matters for cold start and burst admit. It does not measure pytest, coding loops, or sustained agent work. Those are what the throughput sections above cover.

Vera finishes that ready path in 10.7 ± 0.1 seconds. 9575F takes 37.4 ± 0.1 seconds. 9755 takes 88 ± 17 seconds on the same client knobs. Packed throughput and cold start tell different stories: more cores help once the fleet is warm and running Python. Standing the fleet up still cares about single-thread speed and control-plane latency.

![Time to create and ready 1000 sandboxes](../graphs/create_1000_3way.png)

## What to take away

For dense agent tenancy on one socket, Vera still leads packed agent throughput. 9755 closes much of the gap versus 9575F once the node is full (about 1.4× peak, and still ahead at 2000). On the narrower create-and-ready check, 9755 is slower than 9575F. Production tenancy equals peak packed performance. Burst admit still needs the cold-start path to be fast.
