BD=$1; echo "== who/tmux/procs"; who; tmux ls 2>&1 | head -3; su - ubuntu -c "tmux ls" 2>/dev/null | head -2
pgrep -af 'main\.py --benchmark|mpfleet\.py|memfleet\.py|rlp_light_create_fleet|gapfill\.sh' | head -3; echo "firecrackers=$(pgrep -c firecracker)"
echo "== binaries"; echo "runner=$(sha256sum /usr/local/bin/rlp-runner | cut -c1-12) api=$(sudo sha256sum /proc/$(pgrep -nx rlp-api)/exe | cut -c1-12)"
echo "== slice"; ls /sys/fs/cgroup/rlp.slice/cpuset.cpus.effective 2>&1; cat /sys/fs/cgroup/rlp.slice/cpuset.cpus.effective 2>&1; cat /sys/fs/cgroup/rlp.slice/cgroup.subtree_control
echo "== sudo/preflight"; which sudo; ls -la /usr/local/bin/bench-preflight 2>&1
sudo /usr/local/bin/bench-preflight /tmp/pmchk >/dev/null 2>&1; grep -E "create_path_fixes|PREFLIGHT|FAIL" /tmp/pmchk/preflight.txt 2>&1 | head -5; sudo rm -rf /tmp/pmchk
echo "== power domains"; for h in /sys/class/hwmon/hwmon*; do i=$(cat $h/power1_oem_info 2>/dev/null); [ -n "$i" ] && echo "$h: $i avg=$(sudo cat $h/power1_average 2>&1)"; done | head -12
for z in /sys/class/powercap/intel-rapl:[0-9]; do [ -e $z ] && echo "$z $(cat $z/name) e=$(sudo cat $z/energy_uj 2>&1)"; done
ls /dev/ipmi0 2>&1; which ipmitool 2>&1
echo "== key"; k=$(grep -hoP '^RLP_API_KEY=\K.*' $BD/.env | tr -d '"' | head -1); echo "RLP_API_KEY len=${#k}"; curl -s -o /dev/null -w "GET /vms with .env key: %{http_code}\n" -H "Authorization: Bearer $k" "http://127.0.0.1:8088/vms?limit=1"
echo "== harness imports"; cd $BD && $BD/.venv/bin/python -c "
import sys; sys.path.insert(0,'.'); sys.path.insert(0,'scripts')
from harness.rlp_create import build_rlp_resources; import rlp_light_create_fleet as F
print('build_rlp_resources ok; build_client', hasattr(F,'build_client'), '_sandbox_id', hasattr(F,'_sandbox_id'))
from harness import rlp_client_tuning; print('tuning ok')" 2>&1 | tail -3
echo "== python3 for sampler"; sudo python3 --version
