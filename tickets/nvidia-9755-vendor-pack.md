# NVIDIA dual-socket 9755 vendor pack

**For:** us, when NVIDIA returns a JSONL from their internal 9755
**Not for:** NVIDIA (they get the private `daytona-agent-bench` repo)

Private pack: https://github.com/danielgraviet/daytona-agent-bench

Rebuild the tree:

```bash
bash scripts/vendor_nvidia_repo.sh
```

That writes `.generated/daytona-agent-bench` from `vendor/daytona-agent-bench/` plus the agent/RLP allowlist. No old JSONL. Fresh git history lives in that tree. GitHub: `danielgraviet/daytona-agent-bench` (private).

Recipe they run (do not change `--n`):

- `--n 50 --seed 42 -E 8 --hold-then-exec`
- `--rlp-cpu 0.125 --rlp-cpu-max 1 --rlp-memory 0.5`
- levels 44 → 2000
- file `results/agent_hold_then_exec.jsonl`

When that file arrives, put it here:

```text
data/agent/rlp-nvidia-9755-dual/concurrency_<utc>_n50.jsonl
```

Then regenerate the dual-socket Vera / 9J45 charts in this repo. They never clone this tree.
