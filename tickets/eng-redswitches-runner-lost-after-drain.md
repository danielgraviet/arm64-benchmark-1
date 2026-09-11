# Eng ticket: Redswitches runner stuck / creates `no matching capacity`

**Audience:** eng / RLP agents owning the Redswitches (Zen5 9575F) cell  
**Date:** 2026-09-06  
**Host:** `rs-vl-us-15` (`92.205.35.191`, login `root`)  
**Runner id:** `runner-redswitches-1`  
**Reporter:** Daniel Graviet (benchmark client)

---

## One-line ask

Please restore create capacity on Redswitches. After a dense agent ladder and cleanup, **`rlp-runner` never finishes coming up**, the API marks the runner **`lost`**, and every create dies with **`no matching capacity`** within ~60s — including **c=1**. Host is idle (0 Firecracker). We could not finish recovery from the client side.

---

## Symptom (client-visible)

```text
Sandbox <id> failed to start (state=error,
  reason=create job not picked up by any runner within 60s (no matching capacity))
```

API reaper:

```text
canceled create: not picked up within the max queue time
(no matching capacity, lost publish, or crash between commit and publish);
see RLP_CREATE_MAX_QUEUE_SECS  max_queue_secs=60
```

Also:

```text
runner runner-redswitches-1 marked lost
```

| Check | Observed while broken |
| --- | --- |
| `pgrep -c firecracker` | `0` |
| `systemctl is-active rlp-api rlp-proxy rlp-runner` | `active` (runner process exists) |
| `curl http://127.0.0.1:8088/health` | `{"status":"ok"}` |
| `runners.status` | `lost` (stale `last_seen_at`) |
| Creates | fail even at concurrency **1** |

So this is **not** “too many live VMs on the box right now.” The runner is not consuming create jobs.

---

## Context (what we were doing)

1. Ran a dense agent ladder to **c=2000** (`--rlp-cpu 0.025 --rlp-memory 0.0625`, n=50, hold-then-exec). Ladder **completed** (`END_EXIT=0`).
2. After the run, ~**2287 Firecrackers** were left. We drained with `systemctl restart rlp-runner` then `killall -9 firecracker` (fc → 0).
3. Postgres still had those rows as **`vms.status = lost`** (~2287) plus some `pending`/`failed`. Runner capacity JSON still showed **`live_vms: 2287`** and **`status: lost`**.
4. We marked non-deleted VMs deleted in SQL and tried to bring the runner back. Creates still failed.
5. Attempted a short retest ladder `levels 1 8 44 88` (same dense shape, n=50). **c=1 and c=8 failed** immediately with the same pickup timeout — cell was already empty of Firecracker.

Dense ladder JSONL (for reference, already pulled locally):  
`/root/arm64-benchmark-1/data/agent/rlp-x86-c0p025-max1/concurrency_20260906_183809_n50.jsonl`

---

## What we see on the runner process

`rlp-runner` starts, logs only:

```text
runner connecting  runner_id=runner-redswitches-1  nats_url=nats://127.0.0.1:4222
```

It never logs a successful connect / ready / consumer line. Child process stays stuck on network bootstrap:

```text
sudo -n ip link add fcbr0 type bridge
# after killing that once, next hang was:
sudo -n ip addr add 10.103.0.1/20 dev fcbr0
```

Meanwhile **as root**, the same netlink ops are instant:

```text
ip link show fcbr0   # ~1ms
```

`fcbr0` already exists with `10.103.0.1/20`. So the runner is blocked **before** it can heartbeat, which is why the API marks it `lost` and creates get `no matching capacity`.

`systemctl stop rlp-runner` then often hits **TimeoutStopSec** and SIGKILLs the stuck `rlp-runner` + `sudo` (messy restarts).

---

## Strong hypothesis

### 1. `sudo` hung / delayed on hostname DNS (most likely)

While debugging we saw:

```text
sudo: unable to resolve host rs-vl-us-15: Temporary failure in name resolution
```

Root `ip …` works. `sudo -n ip …` as the runner user hangs. That matches classic **sudo trying to resolve the local hostname via DNS** when `/etc/hosts` does not pin `rs-vl-us-15` and resolver is broken/slow.

**Ask eng to verify / fix:**

```bash
hostname
grep "$(hostname)" /etc/hosts || echo 'MISSING_HOSTS_ENTRY'
getent hosts "$(hostname)"
# expect instant:
sudo -n -u ubuntu sudo -n true
sudo -n -u ubuntu sudo -n ip link show
```

If missing, add e.g. `127.0.0.1 rs-vl-us-15` (or the correct LAN IP) to `/etc/hosts`, then restart `rlp-runner` and confirm `runners.status=online` with a moving `last_seen_at`.

### 2. Stale DB capacity after hard Firecracker kill (contributing)

Hard-killing Firecracker without API drain left:

- `vms` rows in `lost` (thousands)
- `runners.capacity.live_vms` stuck high
- runner row `status=lost`

We SQL-marked those VMs `deleted` and zeroed `live_vms` in JSON. That alone did **not** restore creates while the process was still stuck in `sudo`. Still worth eng confirming the intended recovery path after a SIGKILL drain (reaper vs manual SQL).

### 3. NATS secondary

We restarted `rlp-nats`. NATS listens on `127.0.0.1:4222`. Runner still never got past “connecting” because it appears blocked on `sudo ip …` first. Less likely primary once hostname/sudo is fixed, but worth confirming JetStream consumers for `runner-redswitches-1` after the runner is truly online.

---

## What we already tried (please do not assume still clean)

| Step | Result |
| --- | --- |
| `systemctl restart rlp-runner` then `pkill -9 firecracker` | fc=0; runner later unhealthy |
| SQL `update vms set status='deleted' where status in ('lost','pending','failed')` | 2341 rows; creates still fail |
| SQL force `runners.status='online'` + `live_vms=0` | **False healthy** — `last_seen_at` does not advance |
| `docker restart rlp-nats` + restart runner | Still stuck at “runner connecting” |
| Recreate `fcbr0` as root, restart runner | Still hangs on `sudo -n ip …` |
| Kill hung `sudo` child | Runner advances to next `sudo -n ip addr add …` and hangs again |
| c=1 smoke (`n=5`, same dense resources) | Create timeout / no matching capacity |
| Partial attempt: PATH sudo wrapper + systemd drop-in for `rlp-runner` | **Incomplete / may be present on host** — please inspect and remove if unwanted: `/usr/local/libexec/rlp-sudo-wrap/`, `/etc/systemd/system/rlp-runner.service.d/sudo-wrap.conf` |

Cell knobs at time of failure (for context, not necessarily wrong):

```text
RLP_MIN_CPU=0.025
RLP_MIN_MEM_MIB=64
RLP_BURST_MAX_CPU=1
RLP_BURST_MAX_MEM_MIB=4096
RLP_RESERVE_PCT=99
RLP_MAX_LIVE_VMS=2500
```

Backups from the dense-pack change: `/etc/rlp/*.env.bak-pre-dense2k` (if still present).

---

## Suggested eng recovery checklist

1. Fix hostname resolution for sudo (`/etc/hosts` entry for `rs-vl-us-15`).
2. Remove any leftover client-side sudo wrap drop-in if you do not want it.
3. Ensure `fcbr0` + `10.103.0.1/20` are correct **or** let a healthy runner create them once sudo works.
4. `systemctl restart rlp-runner` (avoid stop+SIGKILL loops while sudo is wedged; kill stuck sudo first if needed).
5. Confirm DB: `runners.status=online`, `last_seen_at` advancing, `capacity.live_vms` matches reality, no mass `pending`/`lost` VMs blocking admission.
6. Confirm NATS consumer for this runner is up.
7. Smoke: one create → exec → delete of `dtgraviet/vera-agent-benchmark:v3` (or alpine) via local API.
8. Tell us when green — we will re-run early levels `1 8 44 88` (n=50, dense shape) to fill the chart gaps from the post-drain create wipe.

---

## Why this matters for the benchmark

The dense Zen5 ladder’s **c=44 and c=88** (and our retest of **c=1**) failed creates with this same pickup timeout after cleanup. Higher levels earlier in the day worked once the cell was warm. We need a healthy runner to learn whether early-level failures were only “cell settling / lost capacity accounting” or a real packing issue.

---

## Out of scope / please do not

- Do not need a full re-image unless you decide the box is wedged beyond runner/sudo/NATS.
- Do not rotate the temporary root password in a way that blocks us without notice (or send the new one).
- Avoid bulk-deleting thousands of VMs through the slow path while SSH is the only admin channel (we hit that guidance earlier); prefer runner-driven drain once the runner is healthy.
