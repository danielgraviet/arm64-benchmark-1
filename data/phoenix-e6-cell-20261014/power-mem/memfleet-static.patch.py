from pathlib import Path
p = Path("memfleet.py"); s = p.read_text()
old = '''        r = sb.process.exec(f"sh -c 'echo {B64} | base64 -d > /tmp/m.c && gcc -O3 -o /tmp/m /tmp/m.c && echo built'", timeout=300)
        if int(r.exit_code or 0) != 0 or "built" not in (r.result or ""):
            raise RuntimeError(f"compile failed {r.exit_code} {(r.result or '')[:200]!r}")'''
new = '''        if BIN_B64:
            # MEMFLEET_BIN: ship a statically linked memtest instead of compiling in-guest.
            # Needed where the toolchain image will not boot (Turin: gcc:14 is a 9-layer image and
            # its Firecracker dies; alpine:3.20 is one layer and boots). The measured quantity is
            # unchanged - the same triad binary, one vCPU, 384 MiB - only the delivery differs.
            r = sb.process.exec(f"sh -c 'echo {BIN_B64} | base64 -d > /tmp/m && chmod +x /tmp/m && /tmp/m 1024 0 >/dev/null && echo built'", timeout=300)
        else:
            r = sb.process.exec(f"sh -c 'echo {B64} | base64 -d > /tmp/m.c && gcc -O3 -o /tmp/m /tmp/m.c && echo built'", timeout=300)
        if int(r.exit_code or 0) != 0 or "built" not in (r.result or ""):
            raise RuntimeError(f"prep failed {r.exit_code} {(r.result or '')[:200]!r}")'''
assert s.count(old) == 1
s = s.replace(old, new)
anchor = 'IMAGE = os.environ.get("MEMFLEET_IMAGE", "gcc:14")'
assert s.count(anchor) == 1
s = s.replace(anchor, anchor + '''
_binp = os.environ.get("MEMFLEET_BIN", "")
BIN_B64 = base64.b64encode(open(_binp, "rb").read()).decode() if _binp else ""''')
p.write_text(s); print("memfleet.py patched: MEMFLEET_BIN support")
