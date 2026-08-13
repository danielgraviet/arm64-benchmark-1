# 1,000 concurrent sandboxes: Daytona vs RLP

**To:** CTO / CEO  
**Date:** 13 Aug 2026  
**What we tested:** 1,000 customers asking for a sandbox at the *same time*, each doing a short real eval job (same as a coding-agent / eval workload). Fresh sandbox per job.

This is the “high-value customer” bar (FDE: top accounts today sit around 100–1,000 concurrent).

---

## Bottom line

**100 concurrent works on both.** Every sandbox started. No errors.

**1,000 concurrent does not.** Daytona production dropped most of the requests. RLP got much farther, but still dropped a meaningful share when the connection to the service died.

| | 100 at once | 1,000 at once |
|---|---|---|
| **Daytona (production)** | 100 / 100 succeeded | **290 / 1,000 succeeded** (710 failed) |
| **RLP** | 100 / 100 succeeded | **843 / 1,000 succeeded** (157 failed) |

When a sandbox *did* start, the actual job inside it was fine on both (~2.5 seconds of work). The problem is **getting 1,000 sandboxes created at once**, not the work once they exist.

---

## What broke

**Daytona production** refused a large share of creates with:

> Failed to create sandbox: Total CPU limit exceeded. Maximum allowed: 250.

In plain language: we asked for 1,000 sandboxes; the account is only allowed enough CPU for far fewer. Many requests never got a sandbox. (There were also some “too many requests” responses. Those are a dial we can turn — not the main story.)

**RLP** failed less often (about 1 in 6), and the typical error was:

> Server disconnected without sending a response.

In plain language: RLP tried to take the load, then the service hung up instead of returning a clean “yes” or “no.” That is a reliability / overload problem, not a posted quota.

---

## How to read this for the business

- **100 concurrent** — “normal customer must be amazing.” **We pass this today** on both Daytona and RLP.
- **1,000 concurrent** — “high-value / standard reference.” **We do not pass this yet.** Daytona mostly said no (cap). RLP said yes more often, then dropped connections under the surge.
- The work *inside* a sandbox is not the bottleneck. **Starting a thousand sandboxes at once is.**

---

## Suggested takeaway

RLP is closer to the 1,000-concurrent customer. The remaining RLP issue is the service dropping the call (`Server disconnected without sending a response`) rather than a hard “you’re over quota.” Daytona’s 1,000-run was dominated by the CPU cap (max 250) — raise that and we should re-run before treating Daytona prod as the 1k story.

Next bar after a clean 1,000 is 10,000 (market-share). Do not climb until 1,000 is boring.
