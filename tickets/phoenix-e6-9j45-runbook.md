# OCI Phoenix E6 / EPYC 9J45 — agent-operated bench

Dual-socket **AMD EPYC 9J45** cell (`vedran-test`, region **`phoenix-e6`**, cpu type **`turin-9j45`**).

Access: `ssh -l ubuntu 158.101.39.4`

Operator tree: **[`phoenix-e6/`](../phoenix-e6/)** — isolated from [`nvidia/`](../nvidia/) (9755 only).

Eng already built the cell. `./o start` only syncs the harness + eng SDK. Do **not** run `nvidia/o` on this box.

## Recipe (match Vera / 9755 focus pack)

- Create-ready 1000 + 2000 (`0.025` cpu, `0.0625` mem, disk 1, image `:v3`)
- Dense `44→2000`, `--n 45`, `-E 8`, `--hold-then-exec`, `--rlp-cpu 0.025 --rlp-cpu-max 1`, mem `0.0625`/`0.5`
- **Socket 0 pin** before timed runs (`tickets/9j45-pin-single-socket.sh`)
- Metrics: `host_hw_*.json`, populated `socket_pin` on create meta, `wall_share` boot-phases

## Sequence

```bash
cd ~/arm64-benchmark-1/phoenix-e6
./o start && ./o hw && ./o pin && ./o test
./o clean && ./o 1k
./o clean && ./o 2k
./o clean && ./o full-ladder
```

Mac driver (after SSH is back): `bash scripts/host/run_phoenix_e6_remote.sh`

Results:

- `daniel-focus-here/zen5-9j45-jsonl/`
- `data/agent/rlp-phoenix-e6-c0p025-max1/`
- `phoenix-e6/results/` (hw copies)

Never commit `.env`.
