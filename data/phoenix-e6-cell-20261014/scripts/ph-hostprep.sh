#!/bin/bash
# Phoenix E6 (BM.DenseIO.E6.Ax.192) host preparation for an rlp benchmark cell.
# Matches the HQ Vera host posture: single NVMe for /mnt/data (no RAID, no resync),
# bench sysctls, no udev/libvirtd/fwupd reaction to sandbox veths.
set -euo pipefail
say() { echo "[$(date -u +%T)] $*"; }
CH=/etc/rlp/HOSTCHANGES
sudo mkdir -p /etc/rlp && sudo chmod 750 /etc/rlp
note() { echo "$(date -u +%FT%TZ) $*" | sudo tee -a $CH >/dev/null; }

# ---------- 0. hostname in /etc/hosts (sudo must never hit DNS) ----------
H=$(hostname)
if ! grep -qE "^127\.0\.(0\.1|1\.1).*\b$H\b" /etc/hosts; then
  sudo cp /etc/hosts /etc/hosts.bak-rlp
  printf '127.0.1.1 %s\n' "$H" | sudo tee -a /etc/hosts >/dev/null
  note "hosts: added 127.0.1.1 $H (backup /etc/hosts.bak-rlp)"
fi
say "sudo latency: $( { time sudo -n true; } 2>&1 | awk '/real/{print $2}')  getent: $(getent hosts $H | head -1)"

# ---------- 1. /mnt/data: single NVMe, like HQ Vera (tear down the 12-disk RAID10) ----------
if [ -b /dev/md127 ]; then
  [ "$(sudo du -s --exclude=lost+found /mnt/data 2>/dev/null | cut -f1)" = "0" ] || { say "ABORT: /mnt/data is not empty"; exit 1; }
  say "stopping md127 (empty, initial resync at $(awk '/resync/{print $4}' /proc/mdstat | head -1))"
  sudo umount /mnt/data || true
  sudo mdadm --stop /dev/md127
  for d in /dev/nvme*n1; do sudo mdadm --zero-superblock "$d" || true; done
  sudo sed -i '/\/mnt\/data/d' /etc/fstab
  sudo sed -i '/^ARRAY /d' /etc/mdadm/mdadm.conf
  note "md127 (raid10 x12, empty) stopped and superblocks zeroed; /mnt/data moved to a single NVMe"
fi
if ! findmnt -no SOURCE /mnt/data 2>/dev/null | grep -q nvme0n1; then
  sudo mkfs.ext4 -F -L rlpdata -E lazy_itable_init=0,lazy_journal_init=0 -m 0 /dev/nvme0n1 >/dev/null
  sudo mkdir -p /mnt/data
  U=$(sudo blkid -s UUID -o value /dev/nvme0n1)
  grep -q "$U" /etc/fstab || echo "UUID=$U /mnt/data ext4 defaults,nofail,discard 0 2" | sudo tee -a /etc/fstab >/dev/null
  sudo mount /mnt/data
  note "/mnt/data = ext4 on /dev/nvme0n1 (UUID=$U); nvme1n1..nvme11n1 left unused"
fi
say "/mnt/data: $(findmnt -no FSTYPE,SOURCE,SIZE /mnt/data)"

# ---------- 2. packages ----------
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  nftables iproute2 iptables conntrack e2fsprogs erofs-utils libcap2-bin util-linux xfsprogs jq \
  docker.io git python3 curl ca-certificates sshpass >/dev/null
sudo systemctl enable --now docker >/dev/null 2>&1
say "packages: docker=$(systemctl is-active docker) erofs=$(mkfs.erofs --version 2>&1|head -1) nft=$(nft --version)"

# ---------- 3. bench sysctls (ARP table caps density at ~1k without this) ----------
sudo tee /etc/sysctl.d/90-rlp-bench.conf >/dev/null <<'S'
# rlp bench cell. Default ARP table (1024) caps a host at ~1k sandboxes.
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
fs.file-max = 4194304
fs.inotify.max_user_instances = 65536
S
sudo modprobe nf_conntrack 2>/dev/null || true
sudo sysctl -q --system
note "wrote /etc/sysctl.d/90-rlp-bench.conf (ARP 65536 v4+v6, conntrack 1M, hugepages 0) and applied"
say "arp gc_thresh3=$(cat /proc/sys/net/ipv4/neigh/default/gc_thresh3) hugepages=$(cat /proc/sys/vm/nr_hugepages)"

# ---------- 4. udev: stop open-iscsi forking a handler per sandbox veth ----------
if [ -f /usr/lib/udev/rules.d/70-iscsi-network-interface.rules ] && [ ! -f /etc/udev/rules.d/70-iscsi-network-interface.rules ]; then
  sudo tee /etc/udev/rules.d/70-iscsi-network-interface.rules >/dev/null <<'U'
# rlp bench: shadows /usr/lib/udev/rules.d/70-iscsi-network-interface.rules.
# The stock rule forks net-interface-handler for EVERY net device, incl. thousands of sandbox veths.
SUBSYSTEM=="net", KERNEL=="rlp*|veth*|tap*|fc*", GOTO="rlp_iscsi_end"
SUBSYSTEM=="net", ACTION=="add", RUN+="/usr/lib/open-iscsi/net-interface-handler start"
SUBSYSTEM=="net", ACTION=="remove", RUN+="/usr/lib/open-iscsi/net-interface-handler stop"
LABEL="rlp_iscsi_end"
U
  sudo udevadm control --reload
  note "udev: shadowed 70-iscsi-network-interface.rules to skip rlp*/veth*/tap*/fc* (rm /etc/udev/rules.d/70-iscsi-network-interface.rules to revert)"
fi

# ---------- 5. host services that react to every veth ----------
for u in libvirtd libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket virtlogd virtlockd fwupd; do
  systemctl list-unit-files "$u" >/dev/null 2>&1 && sudo systemctl stop "$u" 2>/dev/null || true
done
for u in libvirtd fwupd; do systemctl list-unit-files "$u.service" >/dev/null 2>&1 && sudo systemctl mask --runtime "$u" >/dev/null 2>&1 || true; done
note "stopped libvirtd/virtlogd/virtlockd/fwupd where present; runtime-masked libvirtd+fwupd (reboot restores)"

# ---------- 6. nofile for the benchmark client ----------
grep -q 'rlp bench nofile' /etc/security/limits.conf || { printf '# rlp bench nofile\n* soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576\n' | sudo tee -a /etc/security/limits.conf >/dev/null; note "limits.conf: nofile 1048576"; }
sudo mkdir -p /etc/systemd/system.conf.d && printf '[Manager]\nDefaultLimitNOFILE=1048576\nDefaultTasksMax=infinity\n' | sudo tee /etc/systemd/system.conf.d/90-rlp-bench.conf >/dev/null
sudo systemctl daemon-reexec

say "DONE. changes logged in $CH"
sudo cat $CH
