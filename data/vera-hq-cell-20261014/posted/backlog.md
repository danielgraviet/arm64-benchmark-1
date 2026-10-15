## What

The API listens with an accept backlog of **128**, so a burst of new client connections overflows the queue. The dropped connection attempts are retried by the client's TCP stack after ~1 s, adding a whole second, sometimes two, to about half of the requests in a burst.

- `api/src/main.rs:847` (`main` @ `d78c74689`): `tokio::net::TcpListener::bind(addr)`.
- tokio's `bind` goes through `mio::net::TcpListener::bind`. mio hard-codes `listen(fd, 128)` on Linux, "the same backlog value as the standard library" (`mio-1.2.2/src/net/tcp/listener.rs:87-94`), whatever `net.core.somaxconn` is set to.
- On the HQ Vera cell, `ss -ltn` shows `127.0.0.1:8088` with `Send-Q 128`. The toolbox proxy on `:9000` (Go) has 4096, and `somaxconn` is 4096.

## Measured

1,000 concurrent `POST /vms` from 16 client processes, each request on a new connection. HQ Vera cell, API from `f0611fa13`; this code is unchanged on `main`.

- `TcpExtListenOverflows` rises by **~550 per burst** (+1,102 across two bursts).
- Time from the client sending `POST /vms` to the API's audit stamp (`audit_logs.created_at`) clusters at **~1.03 s and ~2.05 s**: p90 1.08–1.28 s, and in some runs **p50 1.01–1.03 s**.
- The same burst with the client's connections opened beforehand (0 overflows): **p50 30 ms / p90 56 ms**.

The API's database pool is not the bottleneck. At the default `RLP_DB_MAX_CONNECTIONS=64` at most 16 connections were active in any 0.25 s sample, and 256 vs 64 made no end-to-end difference. API CPU peaked at ~3–4 cores.

## Impact today vs later

On this cell, the burst's end-to-end time is currently set by the runner (#3260, #3261). Requests that reach the API sooner just wait longer in the runner queue, so POST → running p50 is ~1.8 s either way. The 1 s penalty still lands on individual creates during any burst of new connections. It becomes the visible bound once the runner-side bottlenecks are fixed, and it applies to every API route, not just create.

## Options

- Bind with an explicit backlog: `tokio::net::TcpSocket::new_v4()`, `set_reuseaddr(true)`, `bind(addr)`, `listen(4096)`, hand the listener to `axum::serve`. Optionally make it configurable (`RLP_API_LISTEN_BACKLOG`).
- Check the other Rust listeners that face bursts (collector, daemon toolbox `:2280`) for the same default.

Found while measuring the create path step by step on NVIDIA Vera (2026-10-14).
