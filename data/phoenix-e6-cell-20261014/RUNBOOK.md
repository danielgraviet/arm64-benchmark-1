# Running benchmarks on the phoenix-e6 cell

`ssh ubuntu@<turin-host>` — OCI Phoenix `BM.DenseIO.E6.Ax.192`, AMD EPYC 9J45 (Turin),
2 x 96 cores / 384 threads, 2,267 GiB, one 6.9 TB NVMe at `/mnt/data`.
Everything runs on the box: control plane, runner, proxy and the client. Target name: `phoenix-e6`.

**One operator at a time.** Before you start: `tmux ls`, `w`,
`ls /etc/systemd/system/rlp-*.service.d/`. Two operators on one box invalidate each other's runs.

## 0. Preflight — before every rep

```bash
sudo bench-preflight /tmp/pf     # exit 1 means do not run yet; cat /tmp/pf/preflight.txt
```

It gates the confounders that produced wrong published numbers before: a leftover fleet, a filling
netns pool, background CPU, hugepages, the ARP cap, `RLP_BALLOON`, the client FD limit — and records
CPU, kernel, cmdline, binary shas, cpusets and the runner/API env that must be reported with any
result. The rules behind each gate: `~/arm64-benchmark-1/docs/benchmark-methodology.md`.

## 1. Startup — "N sandboxes ready"

Use the **16-process client** for any burst ≥ 500. A single Python process queues on the GIL and
its `post_s` is harness latency, not control-plane time.

```bash
cd ~/arm64-benchmark-1
export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1
set -a; . ./.env; set +a; ulimit -n 1048576

uv run python mpfleet.py --target phoenix-e6 --count 1000 --procs 16 \
  --output results/phoenix-e6-jsonl/ready1k_$(date -u +%Y%m%d_%H%M%S).jsonl
```

The single-process client, for runs that must line up with the older Vera/9575F series:

```bash
uv run python scripts/rlp_light_create_fleet.py --target phoenix-e6 --count 1000 --workers 1000 \
  --image dtgraviet/vera-agent-benchmark:v3 --cpu 0.025 --memory 0.0625 --disk 1.0 \
  --probe 'echo ready' --output results/phoenix-e6-jsonl/ready1k_1p.jsonl
```

Read `ready_wall_s` (burst start → last sandbox ready **and probed**), plus median, p95 and the
failure count. Never quote `ready_wall_s` alone: one hung sandbox turns it into the client timeout.

## 2. Agent throughput — the jobs/s ladder

```bash
TARGET=phoenix-e6 bash scripts/host/run_dense2k.sh     # check the script's levels/n first
```

## 3. Between runs — clean, or the next rep is wrong

```bash
K=$(sudo cat /etc/rlp/bench-api-key)
for id in $(sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc \
    "select id from vms where status not in ('deleted','failed','lost')"); do
  curl -s -o /dev/null -X DELETE -H "Authorization: Bearer $K" http://127.0.0.1:8088/vms/$id
done
pgrep -c firecracker        # must reach 0 before the next rep
```

Tearing down 2,000 sandboxes takes about 6 minutes. Wait it out — a rep started on a dirty host
fails the preflight for good reason.

## 4. Placement

The cell runs **unpinned** by default, which is this box's fast configuration. To pin everything to
socket 0 (the HQ Vera comparison shape):

```bash
SL=/sys/fs/cgroup/rlp.slice
echo 0-95,192-287 | sudo tee $SL/cpuset.cpus $SL/vms/cpuset.cpus
echo 0            | sudo tee $SL/cpuset.mems $SL/vms/cpuset.mems
for u in rlp-api rlp-proxy; do
  sudo systemctl set-property --runtime $u AllowedCPUs=0-95,192-287
  sudo systemctl set-property --runtime $u AllowedMemoryNodes=0
done
for c in rlp-postgres rlp-nats; do sudo docker update --cpuset-cpus 0-95,192-287 --cpuset-mems 0 $c; done
# verify, because both commands fail silently in scripts:
awk '/Cpus_allowed_list|Mems_allowed_list/' /proc/$(pgrep -nx rlp-runner)/status
```

Undo with `0-383` / `0-1`. A pin on `rlp.slice` survives a runner restart — undo it explicitly.

## 5. Knobs you may want, and what they cost

| setting | current | note |
|---|---|---|
| `RLP_MAX_LIVE_VMS` | 3000 | raise for a density ladder past 2k |
| `RLP_NETNS_POOL` | 2100 | must exceed the fleet size; refilling burns CPU for minutes after a restart |
| `RLP_VM_CONCURRENCY` | 512 | create worker pool |
| `RLP_FC_SOCK_WAIT_MS` | 30000 | do not lower: the stock 3 s fails healthy-but-slow spawns under burst (#3212) |
| `RLP_VM_MAXACK` | unset (256) | stock cap on in-flight creates, same as HQ Vera. The 9575F runs 2048 |
| `RLP_BALLOON` | 0 | leave off |

Edit `/etc/rlp/runner.env` (root-owned, `sudo`) and `sudo systemctl restart rlp-runner`, then wait
for the netns pool to refill. `EnvironmentFile=` beats a drop-in `Environment=` — override with a
second `EnvironmentFile=`, not with `Environment=`.

## 6. Where things are

| | |
|---|---|
| cell config | `/etc/rlp/{BUILD,api.env,runner.env,proxy.env,regions.json,bench-api-key}` |
| host changes log | `/etc/rlp/HOSTCHANGES` |
| results + findings | `/mnt/data/bench/` (`FINDINGS.md`, `pin-ab-*`, `burst2k-*`) |
| harness + client | `~/arm64-benchmark-1` (`.env` holds the API key), SDK at `~/rlp` |
| build tree + logs | `~/rlp-build/{src,out,logs}` |
| services | `rlp-api` (:8088), `rlp-proxy` (:9000), `rlp-runner`, containers `rlp-postgres` (:5439), `rlp-nats` (:4222) |
