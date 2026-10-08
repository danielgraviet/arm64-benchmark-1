# OCI Vera bring-up: what broke and how to read it

This is the bare-cell path from the Nix desktop onto a Vera node that had no RLP stack. The harness is public. The eng RLP repo is private. The client has to run on the node. A laptop tunnel measures the tunnel.

Short commands live in `./o`. `git pull` then `./o g` is the usual resume.

## How to diagnose before you change anything

Read the last error line. It names the layer that failed. Do not jump to the next layer.

| What you see | Layer | What it is not |
| --- | --- | --- |
| `401` | API key | Not the image, not the chip |
| `400` validation | Request body (cpu type, arch, disk) | Not "runner is down" |
| `not picked up within 60s` | No runner subscribed to that job yet | Not a missing image |
| Firecracker `PUT /actions 204` then hang | Guest never opened the toolbox | Not an arch typo |
| `permission denied` on `/etc/rlp/*.env` | File is root-only | Not "the knob is unset" |

`systemctl is-active` tells you the process exists. `journalctl -u <unit> -n 40 --no-pager` tells you what it last did. A gauge line like `netns pool ready=2100` means the runner is alive and finished warming its network pool.

## Access and secrets

The Nix desktop cannot paste. Long tokens do not belong in the typed session.

Pack secrets on the Mac, where paste works. `./o` decrypts them into `.env.oci` on the node. You type a short passphrase once.

A script run as `bash ./o l` is a child process. Exports die when it exits. `echo ${#GH_TOKEN}` in your shell stays `0` even when the file is fine. Check the file (`grep` on `.env.oci`) or let `./o g` read `.env.oci` itself.

`GH_TOKEN` must be a fine-grained PAT that can read `danielgraviet/rlp`. A token scoped only to the public harness cannot clone RLP. GitHub will then ask for a username. That prompt is a missing token, not a forgotten password. Ctrl-C. Do not type your GitHub password.

`daytona/rlp` rejects a personal token with "write access not granted." The fork is the right remote.

## Git pin

The eng SDK pin is commit `660e6e3b`. A partial clone does not contain that object, so checkout says the path does not exist. The short branch `bench-pin` on `danielgraviet/rlp` is that same commit. `./o r` deletes a broken `~/rlp` and clones again.

After a successful clone, do not strip the token from `origin` and then `git fetch`. Fetch uses the remote URL. No token means another username prompt.

## Docker

`usermod -aG docker` does not apply to the current session. `permission denied` on `docker.sock` means use `sudo docker`, not "Docker is broken." Postgres and NATS come up only after that.

## Guest kernel

Firecracker needs an arm64 `Image` and an init disk. Those files are not in git. `./o k` builds them on the box. Until they exist, bootstrap stops with `RLP_KERNEL missing`.

Linux `uname` prints `aarch64`. The API and the runner call that same CPU `arm64`. Those names match. A mismatch would be a `400` before any VM starts.

## systemd units copied from upstream

The stock `rlp-proxy` unit requires `wg-quick@wg0`. This box has no WireGuard. A drop-in that clears `Requires=` does not reliably remove that dependency. Replace the unit with one that only waits for the network and the API.

## API health

`./o g` is safe to re-run, but do not mint a new Postgres password while the Docker volume still has the old one. The API then cannot log in and `/health` never returns. Reuse `/opt/rlp/deploy/.env`. If the passwords have already diverged, `./o z` wipes the volumes and the next `./o g` starts clean.

`journalctl -u rlp-api` is the log when health fails. `./o j` prints it.

## SQL and the API key

`psql` prints `INSERT 0 1` as well as the uuid you asked for. If you capture both into a shell variable, the next query sees `org_id='<uuid>INSERT01'` and Postgres says invalid uuid. Quiet mode (`-qAt`) and a single script that ends in one `SELECT` avoid that.

`uv sync` or a bare `uv run` puts PyPI `rlp-sdk` back and drops `cpu_max`, or removes `rlp` entirely (`No module named rlp`). Keep `UV_NO_SYNC=1`. The create script reinstalls `~/rlp/clients/python` editable when that import fails.

`rlp-api mint-key` requires `--permissions all`. Without it the command errors. A sloppy parser then saves a uuid into `.env`. Smoke returns `401` from `rlp/http.py` (`DaytonaAuth`, unauthorized). That file is only the HTTP wrapper. The failure is still the bearer token. A real key looks like `rlp_` plus 32 hex characters. `./o m` mints one and rewrites `.env`. A later `./o s` probes `GET /vms` first and remints on 401 before it spends time on the runner. `load_dotenv` does not replace a `VERA_RLP_API_KEY` already exported in the shell. That stale value wins over the new line in `.env`, and smoke 401s again. Unset the variable, or load the file with `override=True`.

A sandbox id followed by `unauthorized` inside `process.exec` is a different 401. Create talks to the API on `:8088`. Exec talks to the toolbox proxy on `:9000`. The proxy checks the same bearer token in Postgres, and it also requires the literal scope `write:sandboxes`. It uses `RLP_DB_URL` from `/etc/rlp/proxy.env`, not the API's `DATABASE_URL`. If those URLs diverge, create works and exec returns 401. The proxy log line is `toolbox auth denied`. Point `RLP_DB_URL` at the API database and restart `rlp-proxy`.

## cpu_type

`400` with a validation error means the body was rejected before a runner was involved. `cpu_type=vera` must exist in the `cpu_types` table. Fresh databases seed zen and graviton only. The `tier` column is `NOT NULL`, so the insert has to set it.

The runner must advertise the same slug (`RLP_RUNNER_CPU_TYPE=vera`) or it will not subscribe to that job subject.

## "Not picked up within 60s"

The create was accepted. No runner took it before the 60 second cap. That is routing, not the image.

On first boot the runner builds a pool of about 2100 network namespaces. Some of those provisions take around 90 seconds. A smoke started during that window expires while the runner is still warming. `ready=2100` in the journal means the pool is full. Run `./o s` again.

A running process is not the same as a subscribed one. The create subject ends in the cpu type (`jobs.vm.create.vera.vera`). An arm64 runner that never loaded `RLP_RUNNER_CPU_TYPE=vera` only listens for `.arm64` and will ignore that job. `./o w` prints the live process env and the subjects it bound.

`/proc/<pid>/environ` is not readable by other users. Opening it in the shell and then piping to `sudo` still fails, and the script reports region empty even when `runner.env` is correct. Read it with `sudo cat /proc/<pid>/environ`.

Binding NATS consumers is not registration. If `SELECT count(*) FROM runners` is 0, the API has not accepted the heartbeat. A `rejecting runner` line in the API log means it heard the heartbeat and refused it (NVMe-oF, unknown region, bad cpu type). No reject line means the heartbeat never arrived. Compare `NATS_TOKEN` on `rlp-api` with `RLP_NATS_TOKEN` on `rlp-runner`. Also check that the JetStream stream `EVENTS` exists. Heartbeats are published to `events.>`. The runner can bind `JOBS` consumers while `EVENTS` was never created. The provision script sends EVENTS errors to `/dev/null` and prints "exists" anyway, so `JOBS`, `STOPS`, and `DELETES` show up and `EVENTS` does not. The API log then says `runner event consumer exited: stream not found` (code 10059). The same line shows up for the volume consumer, the main event consumer, and the overlay tail. Those are four symptoms of one missing stream. The consumers do not retry. Create `EVENTS` first, then restart `rlp-api`, then the runner. `journalctl -p warning` will not show this. systemd records API stdout as info.

This was the fix for the empty `runners` table on the OCI box. After `EVENTS` existed, the table had one row: id `runner-vera-oci-1`, region `vera`, status `online`, arch `arm64`, cpu type `vera`. That row is the gate. Do not run `./o s` while the count is still 0. A stream list of only `JOBS`, `STOPS`, `DELETES`, and `OBJ_contexts` is the broken state. `EVENTS` has to be on that list.

## Firecracker started, then the client hung

`attaching nic` and `PUT /actions 204` mean the microVM process is running. The MMDS line is normal. This cell does not use the metadata service.

The next wait is the guest toolbox on port 2280. The kernel and init disk can boot Firecracker with an empty userspace. The Daytona daemon is a separate layer, `daemon-arm64.json` plus an erofs blob under `/var/lib/rlp/cas/system`. Without it the toolbox never listens and the client hangs.

`./o a` builds that layer on the box. The public source tag is `v0.190.0`. The name `v0.190.0-rlp6` is a patched build label, not a GitHub tag, so a tarball URL with `-rlp6` returns 404.

The build script then applies every file in `tools/daemon/patches` and renames the output to `v0.190.0-rlpN`, where N is the patch count. Seven patches means the binary is `dist/daemon/v0.190.0-rlp7/daemon-arm64`. An error that says the file is missing under `v0.190.0/` means the compile finished and the next step looked in the wrong directory. Find `daemon-arm64` under `dist/daemon/` before rebuilding.

The smoke image is `python:3.12-slim`. The agent image `dtgraviet/vera-agent-benchmark:v3` matters for the create-ready and dense runs, after the toolbox is already answering.

## Order that actually works

1. `./o g` brings up API, proxy, runner, Postgres, and NATS.
2. `./o k` builds the guest kernel and init disk.
3. `./o m` if smoke returns 401.
4. `./o a` builds the daemon layer.
5. `./o s` after the netns pool is full.
6. `./o 1` then `./o 2` then `./o d` for the benchmark ladders.

Stop at the first red line. Fix that layer. Do not retune CPU knobs while the runner is still warming or the daemon layer is missing.

## Disk full

`no space left on device` on the JSONL writer means the filesystem is full. The JSONL file itself is small. What fills the disk is guest scratch (1 GiB disk per sandbox) plus the Linux source tree `~/erofs-poc` left behind by `./o k`. The Image is already copied to `/var/lib/rlp/kernel`. When the writer dies, the Firecracker processes already started stay up, so `FC` sticks (73 on this box) even though the client has stopped. `./o x` prints usage and deletes `~/erofs-poc`. Then rerun `./o 1`. Its cleanup pass deletes the leftover VMs before it starts again.

The OCI root is 98 GB. After `/scratch` is cleared there is about 71 GB free. Onsite hosts have about 1 TB, so 1000 x 1 GiB fits there and does not fit here. `RLP_MIN_SCRATCH_MIB=1024` was also clamping every request back up to 1 GiB, and `mkfs.ext4` writes that size for real. For this box, create-ready and the dense ladder use 16 MiB disks (`--disk 0.015625`) and the API minimum is 16. 1000 of those are 16 GB. 2000 are 32 GB. The wall time is still the boot and admit path. It is not the onsite cost of formatting a 1 GiB disk. Say that when extrapolating.

`int(0.015625) * 1024` is 0. The client then sends `scratch_mib=0` and every create returns HTTP 400 in about 3 seconds, 0 of 1000. Memory already uses `round()`. Disk must too: `int(round(float(r.disk) * 1024))` is 16 for a 16 MiB disk.

OCI create-ready then did 1000 in 28 seconds and 2000 in 55 seconds, both at 35 sandboxes per second, zero failures. Onsite was about 11 seconds and 27 seconds. After a one-sandbox warmup (0.3 seconds) the 1000-wide fleet stayed at 24 seconds and 41 per second, still 1000 of 1000. Raising create slots to 256 did not move that number. `nproc` is 352, the same logical CPU count as the onsite box.

The onsite 10 second run was pinned to one socket (CPUs `0-87,176-263`, memory node 0). The same pin on OCI made the fleet slower: 41 seconds, 24 per second, still 1000 of 1000. Half the CPUs, a bit under half the rate. Both sockets at 41 per second is the faster setup. Undo the pin with `bash tickets/vera-pin-single-socket.sh undo`. Onsite still does about 93 per second on one socket, so this host does about a quarter of that work per CPU. Guest RAM for the fleet is 64 GiB (1000 times 64 MiB). That is not what the pin changed.

`getconf PAGE_SIZE` on the stock kernel is 4096. The onsite kernel was `6.17.0-1029-nvidia-64k`, so 65536. A 64 MiB guest is 16384 host pages on 4 KB and 1024 host pages on 64 KB. The guest kernel built by `./o k` stays 4 KB (`CONFIG_ARM64_4K_PAGES`). A 4 KB guest can run on a 64 KB host. `./o 6` installs `linux-generic-64k` beside the current kernel and does not reboot. Then `sudo reboot`. If `systemd-detect-virt` is not `none`, the script stops, because a 64 KB kernel will not boot inside a 4 KB virtual machine. Firecracker 1.16.1 fixed virtio on non-4 KB hosts. Smoke (`hello from Olympus`) passed on the 64 KB kernel. The 1000-wide fleet then finished in 22.2 seconds, create max 21 seconds, 45 per second, 1000 good. The 4 KB fleet on both sockets was 24 seconds at 41 per second. 64 KB pages are worth about 10 percent here. Onsite is still about 11 seconds. That 22 second fleet was still a cold boot. The runner starts a snapshot build only on the second miss, and a 0.3 second warmup was treated as a hit, so the 1000 never resumed. `RLP_TEMPLATE_BUILD_AFTER=1` plus waiting for `template build ready` fixed that. The next fleet was `template_hit=1000` and `template_miss=0`, but the wall was 46 seconds at 21.5 per second. The run after that was 19.8 seconds at 50.6 per second. The next one was 18.7 seconds at 53 per second, the best OCI number. Onsite is about 11 seconds. 1.45 times that is about 16 seconds. The fleet print now includes create and probe p50 and p95, and a `boot_phases` block. On tmpfs, with every create a template hit, the wall was 18.8 seconds at 53 per second. Create p50 was 8.9 seconds and p95 was 15.7. Probe p50 was 0.019 seconds. Runner `total_ms` p50 was 74 milliseconds. The sandbox is up in the runner almost immediately. The client spends the rest of the time polling `GET /vms/:id` until the API event consumer marks the row started. A 1024-wide poll fights that consumer for Postgres. Quieting that poll (32 connections, 0.5 second interval) and turning off the events-table write left the wall at 18.3 seconds, 54.6 per second, create p50 still 9.0 seconds. `load_ms` p50 was 17 milliseconds. `total_ms` p50 was 77 milliseconds. The resume is not the queue. Each `POST /vms` ends in a Postgres commit, and this root disk syncs about 55 commits a second. The 9 second median is waiting in that line. `synchronous_commit=off` did not move it. Two runs stayed at about 18 seconds, 54 per second, create p50 9.3 and 9.5 seconds. Recreating the JOBS stream in memory also stayed at 18.4 seconds, 54 per second, create p50 9.0 seconds. The split is in `vera_create_ready_1000_20261008_192630.jsonl`. `post_p50_s` is 5.57 seconds and the slowest POST is 11.9 seconds, so the API accepts creates at about 85 per second. `wait_p50_s` is 3.34 seconds and the slowest wait is 8.0 seconds. The client only learns a sandbox has started at 54 per second. The wall is 1000 divided by that 54, which is 18.3 seconds. Speeding the POST further does not shorten the wall while started-updates stay at 54 per second. 16 seconds needs about 63 started-updates per second. 15 seconds needs about 67. Each create was also emitting assigned, building, and booting before running. The client only waits for running. `RLP_QUIET_PROGRESS=1` skips those three, keeps the running event, and rebuilds `rlp-runner` once. Resume copies a 16 MiB scratch file per sandbox, and ext4 has no reflink, so 1000 copies are 16 GiB of real writes on the 98 GB root disk. The 46 second wave read and wrote that cold. The 19.8 second wave still wrote it. Onsite keeps this on local disk and finishes in about 11 seconds. 1.45 times that is about 16 seconds. `./o 1` now mounts a 48 GiB tmpfs on `/scratch` when MemAvailable is at least 128 GiB and no Firecracker process is running, then rebuilds the template there. Cleanup was also listing 8112 already-deleted rows, about 82 pages, before every fleet. Those rows are deleted from Postgres first. Live sandboxes stay. `./o 6 undo` puts the 4 KB kernel back as the next boot.
