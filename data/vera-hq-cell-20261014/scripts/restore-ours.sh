#!/bin/bash
# Restore OUR bench configuration on HQ Vera. Daniel's changes are moved to a backup dir, never deleted.
set -u
BK=/etc/rlp/daniel-backup-$(date -u +%Y%m%d_%H%M%S); sudo mkdir -p $BK
C=/etc/rlp/HOSTCHANGES
note() { echo "$(date -u +%FT%TZ) $*" | sudo tee -a $C >/dev/null; echo "  $*"; }
echo "== backing up and removing Daniel's service drop-ins"
for f in /etc/systemd/system/rlp-api.service.d/no-event-audit.conf /etc/systemd/system/rlp-runner.service.d/snapshots.conf; do
  [ -f $f ] && { sudo mv $f $BK/; note "moved Daniel's $f -> $BK/"; }
done
echo "== udev.conf"
if grep -q '^children_max=16' /etc/udev/udev.conf; then
  sudo cp -p /etc/udev/udev.conf $BK/udev.conf
  sudo sed -i 's/^children_max=16/#children_max=16  # (Daniel, 2026-10-14 01:17; disabled for our bench config)/' /etc/udev/udev.conf
  sudo udevadm control --reload; note "udev.conf children_max=16 commented out (original in $BK/udev.conf)"
fi
echo "== our density sysctls (Daniel removed 90-platform-bench.conf; ARP gc_thresh3 was back to 1024)"
sudo tee /etc/sysctl.d/90-rlp-bench.conf >/dev/null <<'S'
# rlp bench cell (HQ Vera). Density limits: default ARP table (1024) caps a host at ~1k sandboxes.
net.ipv4.neigh.default.gc_thresh1 = 8192
net.ipv4.neigh.default.gc_thresh2 = 32768
net.ipv4.neigh.default.gc_thresh3 = 65536
net.ipv6.neigh.default.gc_thresh1 = 8192
net.ipv6.neigh.default.gc_thresh2 = 32768
net.ipv6.neigh.default.gc_thresh3 = 65536
net.netfilter.nf_conntrack_max = 1048576
net.ipv4.tcp_max_syn_backlog = 65535
vm.max_map_count = 1048576
vm.nr_hugepages = 0
S
sudo sysctl -q -p /etc/sysctl.d/90-rlp-bench.conf; note "wrote /etc/sysctl.d/90-rlp-bench.conf (ARP 65536, conntrack 1M, hugepages 0) and applied"
echo "== background services reacting to sandbox interfaces (came back with the reboot)"
for u in libvirtd.service libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket virtlogd.service virtlogd.socket virtlogd-admin.socket virtlockd.service virtlockd.socket virtlockd-admin.socket fwupd.service; do sudo systemctl stop $u 2>/dev/null; done
sudo systemctl mask --runtime libvirtd.service fwupd.service >/dev/null 2>&1; note "stopped libvirtd/virtlogd/virtlockd/fwupd again (runtime-masked; reboot restores)"
echo "== runner: ours stays active; pin the FC socket wait for the bench (see #3212)"
grep -q '^RLP_FC_SOCK_WAIT_MS=' /etc/rlp/runner.env 2>/dev/null || sudo grep -q '^RLP_FC_SOCK_WAIT_MS=' /etc/rlp/runner.env || \
  { printf '# bench: avoid spawn-timeout retry storms (#3212); default 3000 retries slow-but-healthy VMs\nRLP_FC_SOCK_WAIT_MS=30000\n' | sudo tee -a /etc/rlp/runner.env >/dev/null; note "runner.env: RLP_FC_SOCK_WAIT_MS=30000"; }
echo "== cgroup pin (Daniel pinned rlp.slice at 01:06; reboot should have cleared it)"
echo "  rlp.slice cpus: $(cat /sys/fs/cgroup/rlp.slice/cpuset.cpus.effective 2>/dev/null)"
sudo systemctl daemon-reload; sudo systemctl restart rlp-api rlp-runner rlp-proxy
for i in $(seq 1 240); do n=$(sudo ip netns list | wc -l); [ $n -ge 2000 ] && break; sleep 5; done
echo "== effective state"
renv() { sudo cat /proc/$(pgrep -nx $1)/environ | tr '\0' '\n' | grep -oP "^$2=\K.*"; }
echo "  runner sha=$(sha256sum /usr/local/bin/rlp-runner | cut -c1-12) EVENT_AUDIT(api)=$(renv rlp-api RLP_EVENT_AUDIT || true) TEMPLATE_BUILD_AFTER=$(renv rlp-runner RLP_TEMPLATE_BUILD_AFTER || true) QUIET=$(renv rlp-runner RLP_QUIET_PROGRESS || true) SOCK_WAIT=$(renv rlp-runner RLP_FC_SOCK_WAIT_MS) VM_CONC=$(renv rlp-runner RLP_VM_CONCURRENCY)"
echo "  dropins: $(ls /etc/systemd/system/rlp-api.service.d/ /etc/systemd/system/rlp-runner.service.d/ 2>/dev/null | tr '\n' ' ')"
echo "  backup dir: $BK -> $(sudo ls $BK | tr '\n' ' ')"
