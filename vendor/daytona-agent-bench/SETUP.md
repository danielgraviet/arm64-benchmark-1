# SETUP

Run this on the dual-socket EPYC 9755, next to the RLP cell. Do not drive the ladder from a laptop. That measures the tunnel.

Do not pin the run to socket 0. We want the packed node.

Do not change `--n`. This recipe is **`--n 50`**, same as the dual-socket Vera / 9J45 maxpack. `--n 45` is a different single-socket experiment. Leave the wrapper alone.

## 1. Cell

```bash
curl -fsS http://127.0.0.1:8088/health
```

If this fails, stop. The RLP operator owns the cell. To pack 2000 sandboxes at 0.125 vCPU / 512 MiB we used:

- `RLP_MAX_LIVE_VMS` at least 2500
- `RLP_MIN_CPU` at most 0.125
- burst cap 1 vCPU / 4 GiB (`RLP_BURST_MAX_CPU=1`, `RLP_BURST_MAX_MEM_MIB=4096`)

## 2. Host

Python 3.13 and a high file descriptor limit. A login-shell `ulimit -Sn` of 1024 plateaus near 1018 sandboxes with `[Errno 24] Too many open files`. That is not silicon.

```bash
bash scripts/bootstrap.sh
```

Or by hand:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
uv python install 3.13
uv sync
ulimit -n 1048576
```

Do not reboot because MOTD said restart required.

## 3. Secrets

```bash
cp .env.example .env
# paste RLP_API_KEY. Leave the URLs on localhost.
chmod 600 .env
```

Never commit `.env`.

## 4. Image

The ladder boots `dtgraviet/vera-agent-benchmark:v3` from Docker Hub. Prefer a Hub pull. Rebuild only if the lab cannot reach Hub (`docker load` a tarball, or `docker build -t vera-agent-benchmark .` then pass `--snapshot` to that tag).

## 5. Smoke

```bash
uv run pytest
uv run main.py --benchmark agent --runner rlp --target local \
  --levels 1 --n 1 --seed 42 -E 1
```

One sandbox, then delete. Confirm `END` / JSONL wrote without `[Errno 24]`.

## 6. The run

```bash
tmux new-session -d -s agent-ladder bash scripts/run_ladder.sh
```

The wrapper raises `nofile`, cleans leftover VMs (paginated GET `/vms`. `Daytona.list()` is page 1 only), then runs:

- image `dtgraviet/vera-agent-benchmark:v3`
- `--n 50 --seed 42 -E 8 --hold-then-exec`
- `--rlp-cpu 0.125 --rlp-cpu-max 1 --rlp-memory 0.5`
- levels `44 88 176 352 528 704 880 1056 1408 1760 2000`

Output is always `results/agent_hold_then_exec.jsonl`. A previous file is copied aside with a UTC stamp.

Follow the log:

```bash
tail -f /tmp/agent-ladder.log
```

## 7. Send the file

When `tmux has-session -t agent-ladder` fails and the log says `END_EXIT=0`, send **`results/agent_hold_then_exec.jsonl`**. That is the only artifact.

If `END_EXIT` is not 0, send the JSONL and the log anyway. Do not start a second recipe.
