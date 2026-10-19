# AMD vendor EPYC 9996

Isolated operator path for the AMD-provided **EPYC 9996** cell (`--target epyc9996`).

**Do not use [`nvidia/`](../nvidia/)** (9755) or [`phoenix-e6/`](../phoenix-e6/) (9J45) on this box.

```bash
cd amd
export GH_TOKEN=…          # Contents:Read on rlp-bench-pin + write on this repo
./o start                  # empty Ubuntu → RLP cell + harness
./o hw
./o pin                    # NUMA node 0 (socket-0 side)
./o test
./o clean && ./o 1k
./o clean && ./o 2k
./o clean && ./o full-ladder
```

Codex on the box is the day-to-day operator. See [`tickets/amd-codex-host.md`](../tickets/amd-codex-host.md). Directions live under [`codex-direction-log/`](../codex-direction-log/).

## Mac break-glass SSH

```bash
cp amd/.env.amd.example amd/.env.amd   # fill AMD_SSH_PASS once
chmod +x amd/ssh amd/scp amd/install_pubkey.sh
./amd/install_pubkey.sh                # password once → pubkey after
./amd/ssh                              # interactive shell
```

Optional `~/.ssh/config` (no password here):

```
Host amd-daytona
  HostName 165.204.53.121
  Port 30208
  User daytonaio
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
```

Results: `daniel-focus-here/zen5-9996-jsonl/` and `data/agent/rlp-epyc9996-c0p025-max1/`.
