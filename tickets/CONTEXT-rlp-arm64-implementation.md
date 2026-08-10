# Running Tasks on the RLP ARM64 Region

Use this guide to run code on RLP's ARM64 (AWS Graviton) test region from any
Python repository. The region is selected by the RLP `target`; it is not
selected by the container image.

## Known-good region configuration

| Setting | Value |
| --- | --- |
| Target | `arm64-test-1` |
| Toolbox proxy URL | `https://toolbox.arm64-test-1.rlp.trydaytona.com/toolbox` |
| Reference image | `python:3.13-slim` |

The toolbox proxy is region-specific. A toolbox URL for the default x86 region
will not work for an ARM64 sandbox.

## Prerequisites

1. Obtain RLP credentials and access to the `arm64-test-1` target.
2. Install the RLP Python SDK. This project uses the known-good version:

   ```bash
   uv add 'rlp-sdk==0.3.2'
   ```

3. Add the API configuration to your repository's untracked `.env` file (or
   export the variables in your shell). Do not commit the API key.

   ```dotenv
   RLP_API_URL=<your RLP API URL>
   RLP_API_KEY=<your RLP API key>
   ```

   Do **not** set `RLP_TOOLBOX_URL` globally to an x86-region URL when running
   ARM64 jobs. Pass the ARM64 URL directly when constructing the client, as in
   the example below. This avoids accidentally routing toolbox calls to the
   wrong region.

## Minimal runnable example

Create `run_arm64.py` in the destination repository:

```python
from __future__ import annotations

from rlp import CreateSandboxFromImageParams, Daytona, DaytonaConfig

ARM64_TARGET = "arm64-test-1"
ARM64_TOOLBOX_URL = "https://toolbox.arm64-test-1.rlp.trydaytona.com/toolbox"

client = Daytona(
    DaytonaConfig(target=ARM64_TARGET, toolbox_url=ARM64_TOOLBOX_URL)
)

sandbox = client.create(
    CreateSandboxFromImageParams(image="python:3.13-slim"),
    timeout=60,
)
try:
    # Replace this command with the repository's actual task command.
    result = sandbox.process.exec(
        "python -c 'import platform; print(platform.machine())'",
        timeout=30,
    )
    print(result.result)
    if result.exit_code != 0:
        raise RuntimeError(f"Task failed with exit code {result.exit_code}")
finally:
    # Always release the sandbox, including when task execution fails.
    client.delete(sandbox)
```

Run it with your preferred environment tool; for example:

```bash
uv run --env-file .env python run_arm64.py
```

The output must be `aarch64` or `arm64`. If it is `x86_64`, do not use the
result as an ARM64 run: check that both the `target` and `toolbox_url` values
above were supplied to `DaytonaConfig`.

## Running a real repository task

Replace the probe command with the command that runs the task, for example:

```python
result = sandbox.process.exec(
    "bash -lc 'git clone <repo-url> /work/repo && cd /work/repo && uv run pytest'",
    timeout=900,
)
```

For a task whose files must be present in the sandbox, use the RLP SDK's
filesystem upload/sync mechanism used by that repository before executing the
command, or bake the task into an OCI image. The **region-selection** portion
does not change: keep the same `DaytonaConfig(target=..., toolbox_url=...)`.

Choose an image that supports ARM64. `python:3.13-slim` is a multi-architecture
image and is known to work. An image available only for `linux/amd64` cannot
run natively on this target.

## Important implementation details

- RLP sandbox creation requires an image or snapshot. Unlike the production
  Daytona SDK, do not rely on a zero-argument `client.create()` call.
- The `target` must be passed when the `DaytonaConfig` is constructed; setting
  it only in task metadata does not place the sandbox in the ARM64 region.
- The RLP SDK's toolbox routing for non-default regions needs the explicit
  `toolbox_url` shown above. Leaving it unset can cause tooling to use the
  locally configured default-region proxy instead.
- Keep every create/run flow in `try`/`finally` and delete the sandbox. This is
  a shared test fleet and leaked sandboxes consume capacity.
- Use a unique sandbox `name` or labels if your workload creates many
  sandboxes, so that failures can be traced and resources can be cleaned up.

## Troubleshooting

| Symptom | Likely cause and action |
| --- | --- |
| `x86_64` from `platform.machine()` | Missing/wrong `target`, or client was built without the ARM64 toolbox URL. Recreate the `DaytonaConfig` with both known-good values. |
| Toolbox connection/error after sandbox creation | The toolbox URL is for another region. Use `https://toolbox.arm64-test-1.rlp.trydaytona.com/toolbox`. |
| Image fails to start | Verify the image publishes a `linux/arm64` manifest; start with `python:3.13-slim` to isolate the problem. |
| Authentication/authorization error | Check `RLP_API_URL`, `RLP_API_KEY`, and that the API key has access to `arm64-test-1`. |
| Sandbox survives a failed task | Ensure deletion is in a `finally` block; also record the sandbox ID/name before running long jobs for manual cleanup. |

## Handoff checklist

- [ ] `rlp-sdk==0.3.2` (or a deliberately validated newer version) is installed.
- [ ] `RLP_API_URL` and `RLP_API_KEY` are configured outside source control.
- [ ] The client uses `target="arm64-test-1"` and the matching ARM64 toolbox URL.
- [ ] A first run prints `aarch64` or `arm64`.
- [ ] The real task uses an ARM64-compatible image and always deletes its sandbox.
