import json, sys, urllib.request
def get(url, tok=None, accept=None):
    r = urllib.request.Request(url)
    if tok: r.add_header("Authorization", f"Bearer {tok}")
    if accept: r.add_header("Accept", accept)
    return json.loads(urllib.request.urlopen(r, timeout=30).read())
ACC = "application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
for ref in sys.argv[1:]:
    repo, tag = ref.split(":"); repo = repo if "/" in repo else "library/" + repo
    tok = get(f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull")["token"]
    idx = get(f"https://registry-1.docker.io/v2/{repo}/manifests/{tag}", tok, ACC)
    archs = {m["platform"]["architecture"]: m["digest"] for m in idx.get("manifests", []) if m.get("platform", {}).get("os") == "linux"}
    out = []
    for arch in ("arm64", "amd64"):
        if arch not in archs: out.append(f"{arch}: MISSING"); continue
        man = get(f"https://registry-1.docker.io/v2/{repo}/manifests/{archs[arch]}", tok, ACC)
        cfg = get(f"https://registry-1.docker.io/v2/{repo}/blobs/{man['config']['digest']}", tok)
        env = cfg["config"].get("Env", [])
        bad = [e.split("=", 1)[0] for e in env if " " in e.split("=", 1)[1]]
        out.append(f"{arch}: env_with_spaces={bad or 'none'}")
    print(f"{ref:28s} " + " | ".join(out))
