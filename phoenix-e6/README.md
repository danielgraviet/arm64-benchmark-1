# OCI Phoenix E6 / EPYC 9J45

Isolated operator path for the dual-socket **9J45** cell (`phoenix-e6` / `turin-9j45`).

**Do not use [`nvidia/`](../nvidia/)** on this box. That tree stays single-socket EPYC 9755 only.

```bash
cd phoenix-e6
./o start          # harness + eng SDK only (cell already live; never reseeds)
./o hw
./o pin            # socket 0
./o test
./o clean && ./o 1k
./o clean && ./o 2k
./o clean && ./o full-ladder
```

Access: `ssh -l ubuntu 158.101.39.4` — see [`tickets/phoenix-e6-9j45-runbook.md`](../tickets/phoenix-e6-9j45-runbook.md).

Results: `daniel-focus-here/zen5-9j45-jsonl/` and `data/agent/rlp-phoenix-e6-c0p025-max1/`.
