# OCI Production Vera Node Testing Notes

## Context

- Testing so far was performed in a restrictive Nix web emulator on a brand new instance, not on a production Vera node.
- The emulator does not allow agents or copy and paste; commands have to be entered manually.
- These results describe the emulator only. They do not establish production-node behavior.
- Test date: 2026-10-06 (from the session environment; verify against the emulator's clock if needed).

## Checks completed

| Check | Observed result | Status / interpretation |
| --- | --- | --- |
| CPU architecture | `aarch64` | Recorded; consistent with ARM64. |
| CPU capacity | 352 visible CPUs; 88 cores; 2 sockets | Reported by tester. |
| Memory | 1.5 TB RAM | Reported by tester. |
| Root filesystem | 98 GB total; 82 GB available | Reported from `df -h /`. |
| Open files limit | 1,024 | Reported from `ulimit -a`; flag for harness owners to confirm whether sufficient. |
| Other limits | Max locked memory 8,192; POSIX message queue 819,200; stack 8,192; max user processes 5,685,031 | Values reported from `ulimit -a`; units/format were not independently verified. |
| Public DNS | `getent hosts example.com` returned two IPv6 address lines, beginning `2606:4700:10::…` | Public hostname resolution works. |
| Configured resolver/search domain | `/etc/resolv.conf` showed `127.0.0.53`, `options edns0 trust-ad`, and search domain `scahybrid.com` | Configuration observed; does not prove Oracle service access. |
| Search-domain lookup | `getent hosts scahybrid.com` returned no output | Name did not resolve in this check. This is not an Oracle endpoint validation. |
| NSS host lookup order | `hosts: files dns` | Host lookups check local files, then DNS. |
| Public HTTPS | `curl -I --connect-timeout 10 https://example.com` returned HTTP 200; Cloudflare; HTML content type | Public HTTPS access works from the emulator. |
| GitHub HTTPS | `curl -I --connect-timeout 10 https://github.com` timed out (curl error 28) | GitHub was unreachable from the emulator during this check. |
| Public Git clone | Shallow clone of `https://github.com/octocat/Hello-World.git` hung and was stopped | Clone could not be completed; repository download is blocked or unreachable from the emulator. |
| Python | Python 3.14.4 | Installed; project compatibility not yet checked. |
| Git | Git 2.53.0 | Installed. |
| Python `requests` | Version 2.32.5 | Import succeeded. |
| Python `pip` | `python3 -m pip list` reported `No module named pip` | Package inventory via pip unavailable. |
| `uv` | `command -v uv` produced no output | Not installed. |
| Daytona CLI | `command -v daytona` produced no output | Not installed; Daytona sandbox creation was not tested. |
| OCI CLI | `command -v oci` produced no output | Not installed. |
| GitHub CLI | `command -v gh` produced no output | Not installed. |
| Local listening sockets | `ss -lnt` showed four listening entries; one reported as `127.0.0.54:53` | DNS-related listener observed; application services not identified. |

## Not tested / blocked

- No Oracle-approved hostname or service endpoint was provided, so Oracle DNS resolution, TLS, authentication, and service access remain unverified.
- GitHub access was unavailable during testing: a shallow clone of `https://github.com/octocat/Hello-World.git` hung, and `curl -I --connect-timeout 10 https://github.com` timed out with curl error 28. Public HTTPS to `example.com` did work. Cloning the benchmark repository and setting up its runner from GitHub are blocked unless an approved mirror or alternate transfer method is provided.
- Daytona API reachability, credentials, sandbox creation, execution, and cleanup remain unverified. The Daytona CLI was absent; ask the Oracle team whether Daytona is supported and authorized in this emulator and for the approved setup procedure.
- No benchmark or RLP runner was cloned or run. The repository's operator instructions say the harness requires the RLP API and toolbox on localhost on the RedSwitches DUT, and that the test must run on the host rather than through a laptop SSH tunnel. Confirm with the Oracle team that the Nix emulator is an approved target and has the required local services before attempting a benchmark.
- No project-specific smoke test was run; the approved command and target were not provided.
- Package inventory and exact environment image/version were not captured.

## Suggested report to managers / Oracle team

> Initial checks were performed in the Nix web emulator, not on a production Vera node. The emulator reports ARM64 (`aarch64`), 352 visible CPUs (88 cores, 2 sockets), 1.5 TB RAM, and a 98 GB root filesystem with 82 GB free. Public DNS and HTTPS to `example.com` work. The open-files limit is 1,024. Python 3.14.4, Git 2.53.0, and `requests` 2.32.5 are present; `uv`, `pip`, Daytona CLI, OCI CLI, and GitHub CLI were not found. GitHub HTTPS timed out and a small public repository clone hung, so benchmark repository setup from GitHub was blocked. No Oracle endpoint, Daytona sandbox, or benchmark runner has been tested. Please provide an approved Oracle hostname, an internal Git mirror or alternate repository transfer method, and the supported benchmark/RLP runner setup for this emulator; also confirm whether Daytona sandbox creation is authorized.

## Next useful steps

Git is reachable on the Vera node now. Bare-cell bring-up + typed-minimal runs live in
[`tickets/oci-vera-bare-cell-runbook.md`](tickets/oci-vera-bare-cell-runbook.md)
(`scripts/host/oci_vera_bootstrap.sh`).

1. Stage arm64 guest kernel + initdisk on the node (not in git).
2. Clone the public harness, run bootstrap with `GH_TOKEN` for private `daytona/rlp` @ `660e6e3b`.
3. Pass `check_vera_parity.sh`, smoke, then create-ready 1k/2k + dense2k under tmux.
4. Ask Oracle for an approved hostname only if you still need Oracle-service DNS/TLS checks outside the cell.
