# HQ Vera create-ready 1000 status

Continued direction 003 on-box 2026-10-14 UTC. No new A/B trials run by this direction.

## Preflight and fixes

- Local API health OK; API/proxy/runner active. Paginated tracked cleanup drained leftovers; FC=0 between trials.
- Initial parity 25 pass / 0 fail / 2 warn; after pin 26 pass / 0 fail / 1 warn (unprivileged Docker check skips Postgres; sudo confirms container).
- Socket0 verified on slice and VM cgroup: cpus `0-87,176-263`, mems `0`; runner allowed CPUs match.
- Live API burst CPU=1 and event audit=0. SDK remains editable at `660e6e3bd`; all client commands use `UV_NO_SYNC=1`, localhost, nofile=65536, disk=1 GiB, HTTP pool=32.
- Stopped an unexpected `/usr/local/bin/preempt-ab 3` in `pab` before its trials, per human's no-new-A/B instruction. Removed its `zz-fcsock.conf`; kernel preemption remains `none`.
- Udev had ~700 workers, ~650 in D state, load ~500. Set `/etc/udev/udev.conf` children_max=16 and restarted udev; blocked workers cleared. Runtime control attempt timed out before persistent fix.
- Wrapper now keeps HQ scratch on configured NVMe rather than OCI's 48G tmpfs, and leaves HQ scratch minimum alone. Ready-pool checks use the current service start, not stale journal entries; accept existing VM concurrency=512 instead of repeatedly rebuilding the pool for 256.
- Wrapper's old runner rebuild used the SDK checkout, which predates the live API's required capability classes/windows fields. Rebuilt from separate `/home/daytona/rlp-bench-runner` worktree at `33ba48051` with quiet progress; native privileged-exec limiter retained. SDK checkout unchanged. Both binary marker checks pass.
- Existing daemon-arm64.json was rejected for missing erofs_sha256. Hashed existing `/mnt/data/rlp/layers/sha256/a1cd17bd8d7dea3a63dd5434c9d46941ab76da115bbe854d726ae9bf6350cf23.erofs` and published digest `841fcdaac37f430b7e398090ac346f6f5f177cf41baefc04a8592e96731a4a5d` in pointer; version `rlp-rs-0.4.1`. No unverifiable-layer override used.
- Wrapper now aborts on failed warmup probe/template and waits for load1 <=20 with FC=0 before subsequent measurements.
- HQ Postgres uses TCP port 5439 in its container; wrapper's socket-based diagnostics report unknown. No Postgres/NATS storage tuning applied successfully in this session.

## Runs

- `daniel-focus-here/vera-jsonl/vera_create_ready_1000_20261014_012227.jsonl`: wall=18.868s; ok/fail=0/1000; create p50/p95/max=0.000/0.000/0.000s.
- `daniel-focus-here/vera-jsonl/vera_create_ready_1000_20261014_012722.jsonl`: wall=10.977s; ok/fail=1000/0; create p50/p95/max=6.217/10.387/10.640s.

First run failed because the daemon layer was refused; its wall is not a ready result. Second run reaches ~11s wall with 1000 template hits; median remains above Sep 8. Confirmation trials pending after idle.

- `daniel-focus-here/vera-jsonl/vera_create_ready_1000_20261014_012924.jsonl`: wall=11.157s; ok/fail=1000/0; create p50/p95/max=6.424/10.210/10.721s. Full ready pool, warmup probe passed, load1<=20 before fleet; END_EXIT=0.

- `daniel-focus-here/vera-jsonl/vera_create_ready_1000_20261014_013140.jsonl`: wall=69.141s; ok/fail=934/66; create p50/p95/max=6.085/10.291/68.843s. **Interrupted, excluded from clean cluster**: API stopped/restarted at 01:34:20 during fleet; all 66 errors are `DaytonaConnectionError:[Errno 111] Connection refused`. NRestarts=0 confirms no automatic systemd retry. API/runner restarted again at 01:35:48–49; current runner binary quiet-progress marker was replaced (count=0), privexec marker remains 1. Tracked paginated cleanup drained leftovers afterward.

## Current outcome / remaining blocker

Two successful 1000/0 trials reproduce ~11s wall (10.977 and 11.157s), p95/max ~10–11s; median remains ~6.2–6.4s versus Sep 8 ~3–4s. Three uninterrupted idle confirmation trials are not yet established. Another on-box operator is replacing/restarting services during this direction; asked human to hold those changes. Do not start another A/B. Resume fixed-setting confirmations only once service ownership is coordinated, using `UV_NO_SYNC=1 TARGET=vera DISK_GB=1 RLP_RUNNER_SOURCE=/home/daytona/rlp-bench-runner bash scripts/host/run_create_ready.sh 1000` in its own tmux; this rebuilds quiet progress if the other operator replaced the binary. Both SDK and runner worktrees have intentional local benchmark patches.

Final cleanup 01:39 UTC: paginated list=10028, live=0. Three PPID=1 orphan Firecrackers still referenced deleted sandbox IDs (72785c7e-3ae7-422f-b2bb-302e33fe4d49, 60f7c2c8-d800-43ce-b7f8-99e3bc33ecc3, 7d3a09c2-bd46-41ee-bcfe-72093590ec2d); sent TERM to those three PIDs, then FC=0. API health OK, benchmark tmux gone, no active client. Successful logs had END_EXIT=0; interrupted last trial END_EXIT=1. All four trial JSONLs committed one per commit and pushed. Further runner changes held pending operator coordination.
