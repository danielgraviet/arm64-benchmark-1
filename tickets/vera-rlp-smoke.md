# Vera onsite RLP cell — SDK smoke + harness

**Cell (LAN-only).** Eng’s access path is an **SSH tunnel** to the Vera host, then hit localhost:

| | Direct (on lab net / WireGuard) | Via SSH tunnel (recommended for laptop) |
| --- | --- | --- |
| Target | `vera` | `vera` |
| API | `http://10.96.8.181:8088` | `http://127.0.0.1:8088` |
| Toolbox | `http://10.96.8.181:9000/toolbox` | `http://127.0.0.1:9000/toolbox` |

`.env` is set to the **localhost** URLs (`VERA_RLP_*`).

## SSH tunnel (leave this running in its own terminal)

```bash
ssh -N -L 8088:127.0.0.1:8088 -L 9000:127.0.0.1:9000 daytona@10.96.8.181
```

Meaning: SSH to `daytona@10.96.8.181`, forward your laptop’s `8088`/`9000` to that host’s local API/toolbox. `-N` = no remote shell, just the tunnel.

You still need **SSH reachability** to `10.96.8.181` (password/key from eng). If `ssh daytona@10.96.8.181` times out, the tunnel cannot start — ask eng about WireGuard or jump host.

## Setup (done in this repo)

- **Host eng SDK (required for Vera):** PyPI `rlp-sdk` lacks `region_routing` / `cpu_type`. Do **not** put a path override in `pyproject.toml` — that breaks sandbox/Docker `uv sync` (`file:///home/daytona/rlp/...` missing). Instead, after `uv sync`:

  ```bash
  # sibling checkout: ../rlp (eng main)
  UV_NO_SYNC=1 uv pip install -e ../rlp/clients/python
  ```

  Prefix **all** Vera host commands with `UV_NO_SYNC=1` so `uv run` does not revert to PyPI.
- `.env` keys (gitignored): `VERA_RLP_API_URL`, `VERA_RLP_TOOLBOX_URL`, `VERA_RLP_TARGET`, `VERA_RLP_API_KEY`
- Harness: `--runner rlp --target vera` → `region_routing=False`, `cpu_arch=arm64`, `cpu_type=vera`, `mode=dedicated`; results under `data/<bench>/rlp-vera/`

## Smoke (image create, no snapshot)

```bash
# terminal 1 — tunnel (keep open)
ssh -N -L 8088:127.0.0.1:8088 -L 9000:127.0.0.1:9000 daytona@10.96.8.181

# terminal 2 — check then smoke
curl -m 5 -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8088/
UV_NO_SYNC=1 uv run python scripts/vera_rlp_smoke.py
```

**Pass:** prints sandbox id, `aarch64`/`arm64`, page size, CPU implementer, `hello from Olympus`, then `smoke OK` / `deleted`.

## Harness runs (Docker Hub images — no native snap bake)

Vera sandboxes cannot reach PyPI (`uv sync` DNS fails). Boot pre-baked Hub images via `--snapshot`:

```bash
# tunnel must be up; editable eng SDK installed (see Setup)
UV_NO_SYNC=1 uv run main.py --benchmark rl --runner rlp --target vera \
  --snapshot dtgraviet/vera-agent-benchmark-rl:latest \
  --levels 1 --n 64 --seed 42 -E 1
```

Chart-style examples (judge chip on `duration_ms`):

```bash
UV_NO_SYNC=1 uv run main.py --benchmark rl --runner rlp --target vera \
  --snapshot dtgraviet/vera-agent-benchmark-rl:latest \
  --levels 1 88 --n 5000 --seed 42 -E 8
```

```bash
UV_NO_SYNC=1 uv run main.py --benchmark rl --runner rlp --target vera \
  --snapshot dtgraviet/vera-agent-benchmark-rl:latest \
  --levels 1 8 22 44 88 --n 64 --seed 42 -E 1
```

JSONL → `data/<benchmark>/rlp-vera/concurrency_*_n*.jsonl`.

Full Day 1–3 copy/paste: `tickets/onsite-vera-gtc-runbook.md`. Do **not** use `build_rlp_snapshot.py --target vera`.
