OUT=/mnt/data/bench/gcc14-diag-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $OUT; sudo chown $(id -u):$(id -g) $OUT
echo "$(date -u +%FT%TZ) runner restart to clear self-cordon (fixes ON drop-ins unchanged); gcc:14 boot diagnosis" | sudo tee -a /etc/rlp/HOSTCHANGES >/dev/null
sudo systemctl restart rlp-runner
ok=0; for i in $(seq 1 120); do n=$(sudo ip netns list | wc -l); if [ "$n" -ge 1995 ]; then ok=$((ok+1)); [ $ok -ge 2 ] && break; else ok=0; fi; sleep 10; done
sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "select capacity->>'self_cordoned', capacity->>'gate_open' from runners"
# watcher: copy every guest serial log + fc.log every second
sudo bash -c "while :; do for d in /run/fc/*/; do b=\$(basename \$d); for f in serial.log fc.log; do [ -f \$d\$f ] && cp \$d\$f $OUT/\$b.\$f 2>/dev/null; done; done; sleep 1; done" & W=$!
cd ~/arm64-benchmark-1 && timeout 420 .venv/bin/python - <<'PY' 2>&1 | tail -4
import sys, time; sys.path.insert(0, "."); sys.path.insert(0, "scripts")
from dotenv import load_dotenv; load_dotenv(".env")
from harness import rlp_client_tuning; rlp_client_tuning.apply()
import rlp_light_create_fleet as F
from harness.rlp_create import build_rlp_resources
from rlp import CreateSandboxFromImageParams
c = F.build_client("vera"); t = time.time()
try:
    sb = c.create(CreateSandboxFromImageParams(image="gcc:14", name="gccdiag", cpu_arch="arm64", cpu_type="vera",
        resources=build_rlp_resources(cpu=0.025, memory=1.0, disk=1.0, cpu_max=1, memory_max=4)), timeout=360)
    print("CREATED in", round(time.time() - t, 1), "s"); r = sb.process.exec("gcc --version | head -1; uname -a", timeout=60); print(r.result); sb.delete()
except Exception as e:
    print("FAILED after", round(time.time() - t, 1), "s:", type(e).__name__, str(e)[:200])
PY
sleep 3; sudo kill $W; sudo chown -R $(id -u):$(id -g) $OUT
ls $OUT | head; echo "--- serial logs: panics/oops/last lines"
for f in $OUT/*.serial.log; do [ -f "$f" ] || continue; echo "== $(basename $f) ($(wc -l < $f) lines)"; grep -m5 -iE "panic|oops|Unable to handle|BUG|error|fail|killed|out of memory|erofs|overlay" "$f" | cut -c1-200; tail -4 "$f" | cut -c1-200; done | head -60
