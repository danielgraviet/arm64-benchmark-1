# Does asking for 1,000 sandboxes favor Vera?

Internal note for Ivan. Same Daytona software on Vera and on EPYC 9575F. No special “if Vera, go faster” branch in RLP.

## The question

Is our create gap really “Vera is faster at one sandbox,” or is it “we flood the machine with a thousand creates, and Vera handles that flood better”?

**The second one.** At a small burst the high-clock chip can win. At a thousand at once, the machine clogs, and Vera stays useful longer.

## What the scale-up shows

Same image. Same warm snapshot. We open N sandboxes together and time until ready.

**Ten at a time.** Average ready time is about **104 ms** on the 9575F and about **116 ms** on Vera. The AMD chip is a little faster. Memory load is similar (about 6–8 ms on both).

**One hundred at a time.** Vera is about **643 ms**. The 9575F is about **716 ms**. The AMD side stretches: loading saved memory jumps to about **178 ms**, and waiting for the guest to answer jumps to about **197 ms**. Vera’s runner time stays near **50 ms**.

**One thousand at a time.** A typical sandbox is ready in about **9 seconds** on Vera and about **16 to 18 seconds** on the 9575F. The whole batch is about **19 seconds** on the OCI Vera box and about **31 to 35 seconds** on the 9575F. Onsite one-socket Vera is about **11 seconds** for a thousand ready vs about **37 seconds** on the 9575F.

So: one (or ten) sandbox is not where Vera wins. The win shows up when we ask for a lot at once.

## What “clog” looks like on the 9575F

When a thousand creates hit at once, three things pile up on Zen5 that barely move on Vera:

1. **Reloading saved memory.** In the thousand-sandbox burst, that step is about **16 ms** on Vera and about **380 to 430 ms** on the 9575F. Same software step. Much slower under load on Zen5.

2. **Waiting for the runner.** A typical request waits about **3.5 to 3.9 seconds** for a runner on Vera and about **8.7 to 9.2 seconds** on the 9575F. The queue behind the host work gets longer.

3. **The last “go” signal.** After the sandbox can already talk, the runner still has to release its startup program on a second port. At ten sandboxes that is fine on both chips. At a thousand, Zen5 retries that release for a median of about **5 to 6 seconds**. Vera does not show that stall.

Plain meaning: we are not comparing one quiet create. We are comparing how each chip behaves when Daytona opens a fleet in one wave. Zen5 gets busy and the later steps wait. Vera keeps those steps short.

## Why the software still matters (without cheating)

RLP does the same wake on both chips. It wakes a saved copy, not a cold boot. Under a big wave that means a lot of memory restore and a lot of control-plane chatter at the same time.

Two settings make that wave heavier than it has to be, on any chip:

- By default a burstable sandbox can still boot sized like a **16-processor / 32 GiB** box even when it only owns a tiny share. On the 9575F, leaving that default on turned a thousand-sandbox start from about **36 seconds** into about **86 seconds**. We now cap burst at one processor for fair runs.
- Vera’s host tracks memory in **64 KiB** pieces. Usual x86 hosts use **4 KiB**. Same RLP code. Less bookkeeping when many restores run together. On one Vera box, big pages vs small pages changed a thousand-ready run by about a **tenth** (roughly 22 s vs 24 s). That is real, but it is not the whole gap.

There is still no ARM-only fast path in the control plane. The accidental help is: our customer-shaped create is a **big simultaneous wake**, and Vera degrades less under that wake.

## What this is not

After the fleet is already open, agent jobs/s (about **13** on Vera vs about **8** on the 9575F) is mostly work inside the sandbox. The request path around the job is under **one percent** of the time. That plateau is the chip under pack, not “how we request creates.”

## Bottom line

Your read is right. For a handful of sandboxes the 9575F can be as fast or faster. For a thousand creates in one wave, we clog the machine, Zen5’s restore and start steps stretch, and Vera keeps up better. That is the coincidental stack×chip story on create. It is not a secret Vera branch in RLP.
