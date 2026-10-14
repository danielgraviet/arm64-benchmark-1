# HQ Vera create-ready 1000 status

Checked on-box 2026-10-14 00:12–00:14 UTC for direction 003.

## Preflight

- `git pull`: already up to date; worktree initially clean.
- Host: `localhost`, `aarch64`; node0 CPU list `0-87,176-263`.
- Local API health: `{"status":"ok"}`. API, proxy, runner all active.
- Firecracker count: 0.
- Parity: **25 pass / 0 fail / 2 warn**. Warnings: slice cpuset empty; unprivileged Docker check could not find Postgres.
- `rlp.slice/cpuset.cpus` and `cpuset.mems`: both empty. Runner ControlGroup `/rlp.slice/rlp-runner.service`. Pin has **not** been applied.
- Installed runner: `RLP_QUIET_PROGRESS` string count 0; `RLP_PRIV_EXEC_CONCURRENCY` string count 1.
- Live runner: snapshots=1, VM concurrency=512, netns pool=2100, template CAS `/mnt/data/rlp/templates`, FC socket wait=3000 ms.
- No `/scratch` mountpoint exists; `/mnt/data` has about 3.3 TiB free. The wrapper's OCI scratch assumptions need checking before execution with HQ disk=1 GiB.

## Blocker: competing experiment

Existing tmux session `ab` is executing `/usr/local/bin/fcsock-ab vera /home/daytona/arm64-benchmark-1 3` (PID 1410254 at inspection). It waits for the netns pool, then runs three 1000-sandbox trials at each of 3000 and 30000 ms socket wait, restarting the runner between arms. Those restarts and experiments conflict with direction 003's pin and idle measurement sequence.

At 00:12:40 load was `364.99, 109.01, 158.31`; at 00:14:06 it was `490.07, 220.44, 193.84`. Many udev workers were runnable or in D state. Runner pool ready count rose from 223 to 662, versus target 2100. This is not an idle measurement environment.

Asked the human whether to stop `ab` or let it finish. No answer at time of this note. Left the competing job and services untouched pending that choice. No create-ready runs or JSONL were produced by this direction yet; target ~11 s wall remains unverified.

Next: resolve competing job, drain and wait for idle, apply tracked socket0 pin, check HQ wrapper setup, then warm template and run 1000 until three clean trials cluster near 11 s. Commit each run separately and push results.
