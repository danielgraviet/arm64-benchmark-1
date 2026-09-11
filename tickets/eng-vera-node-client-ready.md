# Eng coding agents: Vera node client is ready (post-wipe)

**For:** eng (or their coding agents) bringing the RLP runner back up on the NVIDIA Vera cell  
**From:** benchmark client side (Daniel)  
**Date:** 2026-09-05  
**Host:** `ipp8-d15-c2-vera-1` (user `daytona`, LAN `10.96.8.165`)  
**Access:** Axis jump `ssh vera-axis` → lands on this box

Node disk was wiped. Benchmark client is re-bootstrapped. We are blocked on the **RLP API / runner** before any harness smoke.

Related: `tickets/vera-rlp-smoke.md`, `tickets/onsite-vera-gtc-runbook.md`, `tickets/coworker-vera-maxpack-run.md`

---

## What is already done (do not redo)

Layout on the box:

```text
/home/daytona/arm64-benchmark-1   # benchmark harness (git clone + push auth)
/home/daytona/rlp/clients/python  # eng rlp-sdk source (editable install into harness .venv)
```

| Item | Status |
| ---- | ------ |
| apt packages, `git`, `uv` | done |
| `~/arm64-benchmark-1` cloned from `https://github.com/danielgraviet/arm64-benchmark-1.git` | done |
| Repo-local git credential helper (PAT) for push. **Not** `git config --global` | done |
| `uv sync` in the harness (Python 3.13 `.venv`) | done |
| Eng `rlp-sdk` overlay: `UV_NO_SYNC=1 uv pip install -e ~/rlp/clients/python` | done (`region_routing` present) |
| `.env` with `VERA_RLP_*` for on-node client | done (URLs should be localhost, see below) |

### Vera `.env` contract (on-node client)

Harness expects:

```bash
VERA_RLP_API_URL=http://127.0.0.1:8088
VERA_RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox
VERA_RLP_TARGET=vera
VERA_RLP_API_KEY=<cell key>
```

Laptop tunnel URLs are wrong for chip-grade ladders. Client must stay **co-located** on this node.

### Soft rules for anyone sharing this Unix user

- Do **not** set `git config --global credential.helper` or drop a PAT in `~/.git-credentials`. Other people on this Axis/`daytona` home would inherit it.
- Harness git auth lives only under `~/arm64-benchmark-1/.git/`.
- Do **not** put `[tool.uv.sources]` path overrides for `rlp-sdk` in `pyproject.toml`. That breaks sandbox/Docker `uv sync`.
- After any bare `uv sync`, re-run the editable install and keep `UV_NO_SYNC=1` on harness commands. Otherwise uv reverts to PyPI `rlp-sdk` (no `region_routing` / `cpu_type`).

---

## What eng needs to do

Goal: RLP API reachable on this host so the harness can create Vera sandboxes.

1. **Bring up the RLP runner / API** on this cell (or confirm it already listens on this node).
2. **API health** from `daytona@ipp8-d15-c2-vera-1`:

```bash
curl -m 5 -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8088/
```

Pass: `401` or `200`. Fail: hang or connection refused.

3. **Toolbox** on `http://127.0.0.1:9000/toolbox` (path the harness uses via `VERA_RLP_TOOLBOX_URL`).
4. Confirm **`VERA_RLP_API_KEY`** in `~/arm64-benchmark-1/.env` matches the key this cell expects. If you rotate keys, update that file (gitignored).
5. Tell the benchmark owner when (1)–(4) are green. They will run the client smoke (commands below). You do not need to run ladders unless asked.

Optional: if your runner layout needs a different local API bind, say so. We can retarget `.env`. Prefer keeping `127.0.0.1:8088` / `9000` so tickets stay copy/pasteable.

---

## Client smoke (benchmark side, after API is up)

Run from `~/arm64-benchmark-1`. Prefix **every** command with `UV_NO_SYNC=1`.

```bash
export PATH="$HOME/.local/bin:$PATH"
cd ~/arm64-benchmark-1

UV_NO_SYNC=1 uv run python -c "from rlp import DaytonaConfig; assert 'region_routing' in DaytonaConfig.__dataclass_fields__; print('eng rlp-sdk OK')"

UV_NO_SYNC=1 uv run python scripts/vera_rlp_smoke.py

UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target vera \
  --snapshot dtgraviet/vera-agent-benchmark:v3 \
  --levels 1 --n 5 --seed 42 -E 1 --hold-then-exec
```

Hub image `dtgraviet/vera-agent-benchmark:v3` is already multi-arch. No native snapshot bake on Vera (sandboxes lack PyPI DNS).

---

## If something looks broken

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| `Installed rlp-sdk lacks DaytonaConfig.region_routing` | bare `uv sync` / `uv run` without `UV_NO_SYNC` | `UV_NO_SYNC=1 uv pip install -e ~/rlp/clients/python` then retry with `UV_NO_SYNC=1` |
| curl `:8088` refused | runner not up / wrong host | eng starts API on this node |
| auth errors from harness | empty or wrong `VERA_RLP_API_KEY` | align `.env` with cell key |
| creates fail `no matching capacity` | runner admission / live-VM wall | see `tickets/eng-vera-live-vm-wall.md` |

---

## Out of scope for this handoff

- Full max-pack ladders (`tickets/coworker-vera-maxpack-run.md`)
- Rebuilding Hub images
- Laptop SSH tunnel to the cell (not needed when client is on-node)
