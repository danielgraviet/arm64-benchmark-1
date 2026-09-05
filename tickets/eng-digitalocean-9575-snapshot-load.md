# Eng agent brief: DigitalOcean 9575 dual-socket cannot boot sandboxes

**Audience:** eng / RLP agents debugging create/boot on the **digitalocean** cell  
**Date:** 2026-09-01  
**Cell:** `do2001` · `root@168.144.60.156` · on-node API `http://127.0.0.1:8088`  
**Hardware:** AMD EPYC **9575F** (Zen 5). Dual-socket. Linux: **96 cores/socket × 2 = 192 physical CPUs**, SMT off (`Thread(s) per core: 1`).  
**Reporter:** Daniel Graviet (`arm64-benchmark-1`)

---

## One-line ask

Every agent sandbox create on this cell dies at Firecracker **snapshot load**. Please rebuild (or version-match) the **golden clone snapshot** so creates succeed. Until that is fixed we cannot run the dual-socket 9575 ladder that matches Vera / Phoenix 9J45.

---

## What we are measuring

| Item | Value |
|------|--------|
| Repo on box | `/opt/arm64-benchmark-1` (git clone + `--target digitalocean` in `harness/regions.py`) |
| Benchmark | `agent` / `repo-agent-v3` |
| Image | `dtgraviet/vera-agent-benchmark:v3` (Docker Hub, same as Vera/Phoenix) |
| Target | `--target digitalocean` |
| Client | On-node (`do2001`), not a laptop tunnel |
| API / toolbox | `http://127.0.0.1:8088` · `http://127.0.0.1:9000/toolbox` |
| Recipe (blocked) | `--levels 1 --n 1` already fails. Full ladder is `--n 50 --seed 42 -E 8 --hold-then-exec --rlp-cpu 0.125 --rlp-cpu-max 1` |

We do **not** need a local `docker build` of the agent image. Hub `v3` is the intended boot, same as the other cells.

---

## Error you will see

Client: first `rlp create` **hangs**. Host CPU stays idle. No JSONL run rows. After retries the create never reaches exec.

Runner (`journalctl -u rlp-runner`, 2026-09-01 ~16:41–16:44 UTC), every attempt:

```text
clone_load: fc PUT /snapshot/load: status 400:
{"fault_message":"Load snapshot error: Failed to restore from snapshot: Failed to build microVM from snapshot: Failed to restore microVM state: clock_realtime requested but not present in the snapshot state"}
```

Firecracker tail (same event):

```text
Snapshot CPU vendor ID: [AuthenticAMD]
Received Error. Status code: 400 Bad Request. Message: Load snapshot error: ...
clock_realtime requested but not present in the snapshot state
Firecracker exiting with error. exit_code=1
```

API (`journalctl -u rlp-api`) every ~30s:

```text
runner self-cordoned (create-boot-failure health breaker latched):
it is NAK-routing creates to peers and inflating create p95/p99.
Its half-open probe could not clear it — the datapath is likely broken;
consider `systemctl restart rlp-runner`
runner=runner-do2001 region=digitalocean
```

Example VM ids that looped: `d04e242a-0d85-4bbe-8c72-37f4b7ab5cd3`, `93d54a8b-44a4-4475-868e-c58fc721ab16`.

This is **not** guest OOM, agent flake, Hub pull failure, or missing Docker image on the node.

---

## Cell state when we hit it

```text
hostname: do2001
rlp-api: active, listen 0.0.0.0:8088
rlp-runner: active
rlp-proxy: listen *:9000
GET http://127.0.0.1:8088/  → 404 (API is up; root is not a health path)
```

`lscpu` (confirm dual-socket 9575F, not the old one-socket Redswitches box):

```text
Model name:           AMD EPYC 9575F 64-Core Processor
Socket(s):            2
Core(s) per socket:   96
Thread(s) per core:   1
CPU(s):               192
```

---

## What we already tried / ruled out

- On-node client, LAN URLs (`127.0.0.1:8088` / `:9000`). Not a tunnel.
- Fresh clone at `/opt/arm64-benchmark-1`, `.env` copied from `/opt/bench`, `uv sync`.
- Sanity: `UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target digitalocean --levels 1 --n 30 --seed 42 -E 1`
- Log: `/tmp/do-sanity.log` (stops at `rlp create: region='digitalocean' ... image='dtgraviet/vera-agent-benchmark:v3'`).
- Partial JSONL: `/opt/arm64-benchmark-1/data/agent/rlp-digitalocean/concurrency_20260901_164229_n30.jsonl` (no successful runs).

Older rsync tree `/opt/bench` is **not** a git clone. Ignore it for new runs. One earlier `/opt/bench` file (`concurrency_20260901_161710_n30.jsonl`) showed **c=1 success** (8 episodes, p50 duration ~3.3s) then **c=8 all create fails** (~303s create wall). After that, clone_load is 100% fail including c=1. Treat c=1 success as stale / pre-breaker if the golden snap or FC binary changed.

---

## Likely cause

Golden clone snapshot on this host was written by a **different Firecracker** than `rlp-runner` is launching. Restore asks for `clock_realtime` and the snapshot does not have it.

Typical fix (pick one, then confirm a create actually boots):

1. Rebuild the golden clone snapshot **on this host** with the FC binary that `rlp-runner` uses now.
2. Align the Firecracker binary on `do2001` with the snapshot that already exists.
3. Clear the create-boot-failure self-cordon after the datapath works (`systemctl restart rlp-runner` is what the API log already suggests. Restart alone will **not** fix a bad snapshot).

Do not paper this with `RLP_SELF_CORDON_*`. The breaker is correct: boots are failing.

---

## First debug steps on `do2001`

1. `fc-version` / Firecracker binary path used by `rlp-runner` vs the snapshot that clone_load reads.
2. Where the golden snap lives (path / snap id) and when it was built.
3. One create with `journalctl -u rlp-runner -f` and confirm `PUT /snapshot/load` is 200, not 400.
4. After a green create: confirm `self-cordoned` stops, then leave the cell empty (`live_vms: 0`) for the benchmark.

---

## How to verify the fix

From `/opt/arm64-benchmark-1` on the node (not a laptop):

```bash
ulimit -n 1048576
export PATH=$HOME/.local/bin:$PATH
cd /opt/arm64-benchmark-1
UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target digitalocean \
  --snapshot dtgraviet/vera-agent-benchmark:v3 \
  --levels 1 --n 1 --seed 42 -E 1 --hold-then-exec \
  --rlp-cpu 0.125 --rlp-cpu-max 1
```

**Pass:** `failures: 0`, checksum present, `duration_ms` in a few seconds (prior healthy c=1 was ~3.3s p50). Then ping Daniel. We will start the matched dual-socket ladder.

**Fail:** same `clock_realtime` 400 on clone_load, or create still hanging with idle host CPU.

---

## Do not

- Do not tell us to `docker build` the agent image on this node. Hub `v3` is correct.
- Do not treat idle `htop` as "nothing is running." The client is blocked on create retries. Guests never start.
- Do not mix this cell with the old one-socket Redswitches 9575 numbers (`tickets/redswitches-2k-maxpack-run.md`). This box is dual-socket, 192 CPUs, target `digitalocean`.
