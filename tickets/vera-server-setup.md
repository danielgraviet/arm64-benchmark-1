# Vera server setup (on-node RLP client)

**For:** any agent or human running **arbitrary** tests against the NVIDIA Vera RLP cell  
**Not for:** public/default RLP API, Redswitches, or Phoenix (those use different hosts and env keys)

Copy this file into another repo if needed. It does not require the `arm64-benchmark-1` harness.

---

## What this cell is

| | |
|---|---|
| Host | `ipp8-d15-c2-vera-1` (user `daytona`) |
| Access | Axis jump only (see below). Not a normal SSH to the Vera LAN IP. |
| Arch | **aarch64** / Vera (`cpu_type=vera`) |
| Client rule | Run **on the node**. Do not drive load tests through a laptop SSH tunnel. |

Services listen on localhost on the Vera host:

| Service | URL |
|---|---|
| API | `http://127.0.0.1:8088` |
| Health | `http://127.0.0.1:8088/health` |
| Toolbox | `http://127.0.0.1:9000/toolbox` |

---

## SSH access (why agents fail)

You do **not** SSH straight to `ipp8-d15-c2-vera-1`. You SSH to **Axis** (`ssh.axisapps.io`), which drops you into an interactive session on the Vera box as `daytona@…`.

Typical local `~/.ssh/config` shape (values are **per-person / rotating**):

```sshconfig
Host vera-axis
  HostName ssh.axisapps.io
  Port 22
  User <your-axis-session-user-id>
```

### Why `ssh` from another agent often fails

| Mistake | What happens |
|---|---|
| `ssh -o BatchMode=yes …` | Axis closes the connection. Non-interactive / no-TTY auth does not work. |
| No PTY (`ssh host 'cmd'` without `-tt`) | Same: session dies or never lands on `daytona@`. |
| Missing Axis `User` / expired session id | Auth fails. The Axis user id **rotates**. Copying someone else’s stale `User=` line will not work. |
| Treating it like `root@<public-ip>` | Wrong host. There is no public root SSH to this cell for the usual path. |
| Sandbox / CI agent without your Mac’s SSH config + keys | Cannot see `Host vera-axis` or your Axis credentials. |

Human interactive works:

```bash
ssh -o UpdateHostKeys=no vera-axis
# banner from Axis, then: daytona@ipp8-d15-c2-vera-1:~$
```

`UpdateHostKeys=no` avoids noisy host-key prove failures some OpenSSH clients hit on Axis.

### How coding agents actually run remote commands

Use an **interactive PTY** and wait for the `daytona@` prompt, then send shell lines. `expect` is the reliable pattern (sometimes wrap with `script -q` if you need a typescript log). Do **not** use `BatchMode`.

```bash
# one-shot remote command via expect + forced TTY
expect <<'EOF'
set timeout 60
log_user 1
spawn ssh -o UpdateHostKeys=no -tt vera-axis
expect -timeout 45 "daytona@"
send {echo OK; hostname; whoami; curl -fsS http://127.0.0.1:8088/health; echo; echo DONE}
send "\r"
expect -timeout 40 "DONE"
send "exit\r"
expect eof
EOF
```

Longer jobs: start them in `tmux` on the node inside the same expect session, then exit SSH. Attach later with another expect/`tmux attach`.

Checklist for the other agent’s machine:

1. Working interactive `ssh vera-axis` as a human first (Axis account provisioned for that person).
2. `Host vera-axis` in **that** machine’s `~/.ssh/config` with a **current** Axis `User`.
3. Agent invocations use `-tt` + expect (or an equivalent interactive PTY driver), never `BatchMode`.
4. Agent runtime has network egress to `ssh.axisapps.io:22` and access to the user’s SSH config/keys (not a sealed sandbox without them).

If Axis access cannot be granted to that agent’s environment, someone with working `vera-axis` must either run commands for them or open a tunnel from a machine that can SSH (smokes only: see Laptop tunnel below).

---

## Connect and sanity-check

Once you have an interactive shell on the node:

```bash
# prompt should be: daytona@ipp8-d15-c2-vera-1
systemctl is-active rlp-api rlp-proxy rlp-runner
curl --fail --silent --show-error http://127.0.0.1:8088/health
# expect: {"status":"ok"} (or HTTP 200)

# is another heavy test already running?
pgrep -af '[p]ython.*main.py|firecracker' | head
pgrep -c firecracker || echo 0
```

If health fails or creates hang, stop and ask whoever owns the cell. Do not restart `rlp-*` unless you own ops on this box.

---

## Environment variables

Put these in a **gitignored** `.env` next to your test code (or export them in the shell). On-node values only:

```dotenv
VERA_RLP_API_URL=http://127.0.0.1:8088
VERA_RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox
VERA_RLP_TARGET=vera
VERA_RLP_API_KEY=<cell key>
```

Notes:

- Ask the cell owner for `VERA_RLP_API_KEY`. Do not commit it.
- Laptop tunnel URLs (`127.0.0.1` on your Mac) are fine for tiny smokes only. Chip-grade or concurrency tests must use the co-located client on Vera with the URLs above.
- Do **not** point this client at public `https://api.*.rlp.trydaytona.com` hosts and call it Vera.
- If your code only reads `RLP_API_URL` / `RLP_API_KEY` / `RLP_TOOLBOX_URL`, set those to the same localhost values and still pass Vera placement fields in code (below).

---

## SDK: eng overlay + `UV_NO_SYNC`

PyPI `rlp-sdk` is **not enough** for Vera. It lacks `region_routing` / `cpu_type` (and related placement fields). You need eng’s editable SDK.

On this host a sibling checkout usually exists at `~/rlp/clients/python`. Prepared bench env: `/opt/bench` (also uses that overlay).

### Install into *your* project venv

```bash
export PATH="$HOME/.local/bin:$PATH"
cd /path/to/your/project
uv sync   # once, if you use uv

# overlay eng SDK (do not put a path override in pyproject.toml)
UV_NO_SYNC=1 uv pip install -e ~/rlp/clients/python
```

### Every run command

Prefix **every** `uv run` / harness invocation with `UV_NO_SYNC=1`:

```bash
export UV_NO_SYNC=1
export PYTHONUNBUFFERED=1
```

Bare `uv sync` or `uv run` without `UV_NO_SYNC` reverts to PyPI and Vera creates break.

Verify:

```bash
UV_NO_SYNC=1 uv run python -c \
  "from rlp import DaytonaConfig; assert 'region_routing' in DaytonaConfig.__dataclass_fields__; print('eng rlp-sdk OK')"
```

### Soft rules (shared `daytona` user)

- Do **not** `git config --global credential.helper` or write a PAT into `~/.git-credentials`.
- Do **not** add `[tool.uv.sources]` path overrides for `rlp-sdk` in shared `pyproject.toml` files.
- Prefer your own workdir under `/tmp`, `~/`, or a project clone. `/opt/bench` is a prepared harness tree. Do not wipe it.

---

## Minimal create → exec → delete (any test)

Works from any Python project with the eng SDK + env above.

```python
import os
from dotenv import load_dotenv
from rlp import CreateSandboxFromImageParams, Daytona, DaytonaConfig, Resources

load_dotenv()  # or export VERA_RLP_* in the shell

client = Daytona(
    DaytonaConfig(
        api_url=os.environ["VERA_RLP_API_URL"],
        api_key=os.environ["VERA_RLP_API_KEY"],
        toolbox_url=os.environ["VERA_RLP_TOOLBOX_URL"],
        target=os.environ.get("VERA_RLP_TARGET", "vera"),
        region_routing=False,  # pin to this cell; no catalog fan-out
    )
)

sandbox = client.create(
    CreateSandboxFromImageParams(
        image="python:3.12-slim",  # must be multi-arch / arm64-capable
        name="vera-test",
        cpu_arch="arm64",
        cpu_type="vera",
        mode="dedicated",
        resources=Resources(cpu=1, memory=1, disk=1),
    ),
    timeout=120,
)
try:
    r = sandbox.process.exec("uname -m; python3 -c 'import platform; print(platform.machine())'", timeout=60)
    print(r.result)
    assert r.exit_code == 0
finally:
    client.delete(sandbox)
```

```bash
UV_NO_SYNC=1 uv run --env-file .env python your_test.py
```

**Pass:** `aarch64` / `arm64` printed, then delete succeeds.

Replace the `exec` string (or add more execs) with whatever your test needs.

### Placement fields that matter

| Field | Value | Why |
|---|---|---|
| `region_routing` | `False` | Stay on this cell’s API |
| `target` | `vera` | Cell name |
| `cpu_arch` | `arm64` | Guest arch |
| `cpu_type` | `vera` | Vera placement |
| `mode` | `dedicated` | Typical for this cell |

Optional resource knobs (`cpu`, `memory`, `disk`, and burst max if your SDK build supports them) depend on cell `MIN_*` / burst env. Start with `cpu=1, memory=1, disk=1` for smokes.

---

## Images / snapshots

- Prefer **pre-baked multi-arch Hub images**. Vera guests often lack outbound PyPI DNS, so `uv sync` / `pip install` inside the sandbox can fail.
- Do not assume x86-only images will boot.
- If your test needs a custom rootfs, build/push a multi-arch image first, then boot it by name/digest.

---

## Optional: prepared `/opt/bench` tree

If you only need a working Python + eng SDK quickly:

```bash
# interactive Axis SSH (or expect -tt pattern above), then:
cd /opt/bench
export PATH="$HOME/.local/bin:$PATH"
export UV_NO_SYNC=1
export PYTHONUNBUFFERED=1
```

`.env` with `VERA_RLP_*` should already be present for that tree. Confirm keys exist (`grep '^VERA_RLP_' .env | sed 's/=.*/=***/'`). Use this for smokes or short scripts. For a different repo’s long tests, clone/copy your project onto the node and overlay the eng SDK into **that** venv instead of mutating `/opt/bench` casually.

---

## Laptop tunnel (smokes only)

Only for one-off debugging from a laptop when you cannot SSH interactively. Throughput will measure the tunnel, not Vera.

```bash
# on laptop: keep this running
ssh -N -L 8088:127.0.0.1:8088 -L 9000:127.0.0.1:9000 vera-axis
```

Then point `VERA_RLP_*` at `http://127.0.0.1:8088` / `http://127.0.0.1:9000/toolbox` on the laptop. Still need eng SDK + `region_routing=False`. Do **not** use this for concurrency ladders.

---

## Failure hints

| Symptom | Likely cause | Fix |
|---|---|---|
| `DaytonaConfig` missing `region_routing` | PyPI SDK / bare `uv run` | Reinstall eng editable + `UV_NO_SYNC=1` |
| curl `:8088` refused | API/runner down | Check `systemctl is-active rlp-api rlp-proxy rlp-runner` |
| 401 / auth errors | Wrong or empty key | Align `VERA_RLP_API_KEY` with cell |
| Creates timeout right after a big drain | Cell still settling | Wait, smoke one create, then retry |
| `no matching capacity` / live-VM wall | Admission / packing limits | Lower concurrency or ask cell owner about `MAX_LIVE` / mins |
| Guest cannot `pip` / `uv` | No PyPI DNS in sandbox | Use a pre-baked image |
| Wrong arch in guest | Bad image or missing `cpu_arch`/`cpu_type` | Multi-arch image + Vera placement fields |

---

## Cleanup hygiene

- Always `client.delete(sandbox)` (or equivalent) in a `finally`.
- After large runs, leftover Firecrackers can pin load. Prefer `systemctl restart rlp-runner` (owned ops) over bulk-killing thousands of VMs in one shot.
- Check `pgrep -c firecracker` and loadavg before starting a heavy test so you do not stack on someone else’s ladder.

---

## Out of scope

- Public default-region RLP (`RLP_API_URL=https://…`) — different handoff
- Redswitches / Zen5 x86 cell
- Changing cell `api.env` / `runner.env` unless you are cell ops
