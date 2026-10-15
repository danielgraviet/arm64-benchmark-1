# NVIDIA Zen5 (EPYC 9755 / phoenix-e6 9J45)

**Start here → [RUNBOOK.md](RUNBOOK.md)**

Typed operator for Zen5 bare cells: single-socket **9755** bring-up, or the already-live OCI **phoenix-e6 / 9J45** cell (`./o start` → `SKIP_CELL`, then `./o pin` for socket 0).

```bash
cd nvidia
# Preferred: NVIDIA_PASS='…' ./o load   (Mac packed secrets/nvidia-zen5.enc)
# Or:        export GH_TOKEN='…'
./o start
./o hw
./o test
./o clean && ./o 1k
./o clean && ./o 2k
./o clean && ./o full-ladder
```

See [RUNBOOK.md](RUNBOOK.md) for passphrase pack, PAT paste, and tarball bring-up.

| Command | What it does |
|---------|----------------|
| `./o start` | Clone RLP fork, build cell, mint key, harness + eng SDK (phoenix-e6: harness only) |
| `./o pin` | 9J45: pin `rlp.slice` to socket 0 |
| `./o hw` | Chip / RAM / cooling / server inventory |
| `./o test` | Parity vs Vera knobs + one-sandbox smoke |
| `./o clean` | Drain sandboxes; fail if Firecracker orphans remain |
| `./o 1k` / `./o 2k` | Create-ready 1000 / 2000 (tmux) |
| `./o full-ladder` | Dense agent ladder 44→2000, n=45 (tmux) |

Root `./o` is OCI Vera-only. Do not use it on this box.

Results: `daniel-focus-here/zen5-9755-jsonl/` (9755) or `zen5-9j45-jsonl/` (phoenix-e6), plus `nvidia/results/` hw copies.
