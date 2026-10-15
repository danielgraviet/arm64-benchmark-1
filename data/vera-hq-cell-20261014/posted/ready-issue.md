## What

A Linux sandbox is marked `running` after **one TCP accept on the daemon's toolbox port `:2280`**. No bytes are exchanged and no process is spawned. After `running` is emitted, nothing checks the guest's health. So a guest whose daemon listener is bound but whose process spawning is wedged is reported `running` **indefinitely**. The first user `exec` is what discovers it.

Code on `main` (`44df1036a`):

- `runner/internal/vm/toolbox.go:391-440` (`WaitToolboxErr`): dials `vmIP:2280` with a 200 ms timeout every 10 ms. The first successful dial closes the connection and returns true. The comment at l.368-374 says this is deliberate ("A successful TCP accept is sufficient to gate `running`").
- The emit sites gated on it:
  - cold boot: `linuxvm/boot.go:395` → `EmitVm(VmRunning)` l.483-488
  - template clone: `template.go:1491-1506` → `linuxvm/boot.go:571-578`
  - persistent: `persistent_boot.go:284` → `linuxvm/boot.go:660-667`
- Restore and resume are weaker still. `runner/internal/runner/vm.go:558-568` (`awaitToolboxBeforeRunning`) is a best-effort 10 s probe that logs "emitting running anyway" when it fails.
- `TriggerEntrypoint` (`toolbox.go:671-719`) gets a 200 from `daemon/crates/daemon/src/control.rs:7-20` before anything is spawned. The actual spawn happens later in a background task (`daemon/crates/daemon/src/lib.rs:208-226`), and a failure there is only written to guest stderr. So the entrypoint trigger does not prove that spawning works either.
- After `running`: `WatchExit` (`runner/internal/runner/boot.go:81-125`) only waits for the VMM process to exit, and the self-cordon streak (`runner.go:285-295`) counts boot failures, not guest health.

`daemon/AGENTS.md` (GOTCHAS) describes exactly this failure shape: "`/version` looks fine and only exec wedges". Here the gate doesn't even call `/version`.

## Observed

On an NVIDIA Vera benchmark cell (`f0611fa13`-based runner with the same TCP-only gate, daemon `rlp-rs-0.4.1`, stock Firecracker v1.16.1, 64 KiB host pages), template clones occasionally resumed with:

- the runner reporting the sandbox `running`, and the API showing `running`;
- toolbox HTTP requests answered by the daemon;
- a `POST /process/execute` of `echo ready` never completing, ending in the daemon's `command execution timeout` (408).

Rates: about 1 in 10,000 for 1-vCPU clones across ~60k creates; 20–55% for 2-vCPU clones (see #3213, which tracks the guest-side cause). The benchmark harness counted these as failures only because it probes with a real exec. A user would get a sandbox that the platform says is healthy and whose first command hangs.

**Caveat:** that daemon predates the process engine (#278). I have not reproduced the hang on the current engine daemon, so the guest-side rate on `main` is unknown. The gate gap described above exists on `main` regardless of which daemon version runs.

## Proposal (for discussion)

1. **Gate `running` on a real round trip**, ideally one that exercises spawn and reap: a cheap `true` exec through the toolbox (the template warmup already does this once per template: `WarmToolboxInNetns`, `toolbox.go:459-544`), or a daemon readiness endpoint that proves the engine and reaper are live. It needs a short timeout. On failure, tear down and retry the clone, the same as a failed TCP gate today.
2. Measure the cost first. On Vera a 1k burst currently reaches all-ready in ~9–10 s (pinned to one node). A per-clone exec adds one request per sandbox through a path we already know handles 1k concurrent `echo ready` with p50 30–47 ms.
3. Optional: a low-rate post-`running` liveness probe for long-lived sandboxes. That is a separate design question.

Also fix the doc drift: `daemon/crates/daemon/src/lib.rs:12` and `daemon/AGENTS.md:248` say the runner's gate is "TCP connect + `GET /version`", but no runner or proxy code sends `GET /version`.

## Why filed separately

Found while benchmarking Vera vs EPYC startup. It is out of scope for #3213, which is about why the guest wedges; this issue is about the platform reporting a wedged guest as healthy.

Related: #3213, #3212, #278
