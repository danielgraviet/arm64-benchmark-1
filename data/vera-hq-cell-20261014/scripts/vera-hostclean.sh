#!/bin/bash
# Remove host background work that reacts to every sandbox network interface.
# Same class as the OCI fix (unfiltered open-iscsi udev rule). All reversible; recorded in /etc/rlp/HOSTCHANGES.
set -e
C=/etc/rlp/HOSTCHANGES
note() { echo "$(date -u +%FT%TZ) $*" | sudo tee -a $C >/dev/null; echo "$*"; }
# 1) shadow the unfiltered open-iscsi rule: same rule, but skip sandbox interfaces
sudo tee /etc/udev/rules.d/70-iscsi-network-interface.rules >/dev/null <<'R'
# rlp bench: shadows /usr/lib/udev/rules.d/70-iscsi-network-interface.rules.
# The stock rule forks net-interface-handler for EVERY net device, incl. thousands of sandbox veths.
SUBSYSTEM=="net", KERNEL=="rlp*|veth*|tap*|fc*", GOTO="rlp_iscsi_end"
SUBSYSTEM=="net", ACTION=="add", RUN+="/usr/lib/open-iscsi/net-interface-handler start"
SUBSYSTEM=="net", ACTION=="remove", RUN+="/usr/lib/open-iscsi/net-interface-handler stop"
LABEL="rlp_iscsi_end"
R
sudo udevadm control --reload
note "udev: shadowed 70-iscsi-network-interface.rules to skip rlp*/veth*/tap*/fc* (remove /etc/udev/rules.d/70-iscsi-network-interface.rules to revert)"
# 2) unused services reacting to interface events (0 libvirt VMs defined)
for u in libvirtd.service libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket virtlogd.service virtlogd.socket virtlogd-admin.socket virtlockd.service virtlockd.socket virtlockd-admin.socket fwupd.service; do
  sudo systemctl stop $u 2>/dev/null || true
done
sudo systemctl mask --runtime libvirtd.service fwupd.service >/dev/null 2>&1 || true
note "stopped libvirtd(+sockets), virtlogd, virtlockd, fwupd; runtime-masked libvirtd+fwupd (reboot restores; 'systemctl unmask --runtime' to revert now)"
