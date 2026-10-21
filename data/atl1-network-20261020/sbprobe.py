import os, sys, time
from pathlib import Path
ROOT = Path("/home/ubuntu/arm64-benchmark-1")
sys.path.insert(0, str(ROOT)); sys.path.insert(0, str(ROOT / "scripts"))
from dotenv import load_dotenv
load_dotenv(ROOT / ".env")
os.environ.setdefault("RLP_HTTP_READ_TIMEOUT_S", "180")
from harness import rlp_client_tuning
rlp_client_tuning.apply()
import rlp_light_create_fleet as F
c = F.build_client("atl1")
sb = c.create(F.build_params(target="atl1", image="alpine:3.20", cpu=1, memory=1.0, disk=1.0, idx=9052), timeout=120)
for cmd in sys.argv[1:]:
    r = sb.process.exec(cmd, timeout=120); print(f"$ {cmd}\n[exit {r.exit_code}] {r.result.strip()}\n", flush=True)
c.delete(sb)
