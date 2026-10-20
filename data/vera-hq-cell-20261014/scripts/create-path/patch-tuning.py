p = "/home/daytona/arm64-benchmark-1/harness/rlp_client_tuning.py"
s = open(p).read()
if "RLP_HTTP_READ_TIMEOUT_S" not in s:
    old = '''    max_conn = int(_env_f("RLP_HTTP_MAX_CONNECTIONS", 512))
'''
    new = '''    max_conn = int(_env_f("RLP_HTTP_MAX_CONNECTIONS", 512))
    # Client-side read timeout. The SDK default is read=None: a guest that wedges mid-exec (e.g. a post-resume
    # kernel oops, daytona/rlp#3213/#3229) then hangs the whole ladder forever, because the daemon-side command
    # timeout never fires. 0/unset keeps the SDK behaviour.
    read_timeout = _env_f("RLP_HTTP_READ_TIMEOUT_S", 0) or None
'''
    assert s.count(old) == 1; s = s.replace(old, new, 1)
    old2 = '''            timeout=httpx.Timeout(30.0, read=None),
            limits=httpx.Limits('''
    assert s.count(old2) == 1
    s = s.replace(old2, '''            timeout=httpx.Timeout(30.0, read=read_timeout),
            limits=httpx.Limits(''', 1)
    open(p, "w").write(s); print("patched")
