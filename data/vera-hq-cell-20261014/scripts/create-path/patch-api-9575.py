import sys
p = "/root/rlp-bench-src/api/src/main.rs"
s = open(p).read()
if "RLP_API_LISTEN_BACKLOG" in s:
    print("already patched"); sys.exit(0)
old = "    let listener = tokio::net::TcpListener::bind(addr).await?;"
assert s.count(old) == 1, f"anchor count={s.count(old)}"
new = '''    // Accept backlog (issue #3269). tokio's TcpListener::bind goes through mio,
    // which hard-codes listen(fd, 128) on Linux whatever net.core.somaxconn is
    // (mio/src/net/tcp/listener.rs: "the same backlog value as the standard
    // library"). A burst of new client connections overflows that queue, the
    // kernel drops the SYNs, and the client's TCP stack retries ~1s later:
    // measured ~550 TcpExtListenOverflows per 1000-create burst, with the
    // client-observed time to reach this process clustering at 1.03s / 2.05s.
    // Bind explicitly so the backlog is ours to set; default preserves the old
    // 128 while this is being measured.
    let backlog: u32 = std::env::var("RLP_API_LISTEN_BACKLOG")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(128);
    let listener = {
        let sock = if addr.is_ipv4() {
            tokio::net::TcpSocket::new_v4()?
        } else {
            tokio::net::TcpSocket::new_v6()?
        };
        sock.set_reuseaddr(true)?;
        sock.bind(addr)?;
        sock.listen(backlog)?
    };
    tracing::info!(backlog, "rlp-api accept backlog");'''
open(p, "w").write(s.replace(old, new, 1))
print("patched main.rs")
