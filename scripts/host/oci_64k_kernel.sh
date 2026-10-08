#!/usr/bin/env bash
# Install Ubuntu's 64 KB page kernel beside the running 4 KB kernel.
# Does not reboot. Does not remove linux-generic.
#
#   ./o 6         install and make generic-64k the next boot
#   ./o 6 undo    make the 4 KB generic kernel the next boot
set -euo pipefail

order_file="/etc/default/grub.d/local-order.cfg"

write_order() {
  local flavour="$1"
  sudo -n mkdir -p /etc/default/grub.d
  sudo -n tee "${order_file}" >/dev/null <<EOF
GRUB_FLAVOUR_ORDER=${flavour}
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=10
EOF
  sudo -n update-grub
}

if [[ "${1:-}" == "undo" || "${1:-}" == "4k" ]]; then
  echo "next boot: 4 KB kernel (generic)"
  write_order "generic"
  echo "4k kernel stays installed. next: sudo reboot"
  exit 0
fi

pages="$(getconf PAGE_SIZE)"
echo "page size now: ${pages}"
if [[ "${pages}" == "65536" ]]; then
  uname -r
  echo "already 64 KB pages"
  exit 0
fi

virt="$(systemd-detect-virt 2>/dev/null || true)"
echo "virt: ${virt:-none}"
if [[ -n "${virt}" && "${virt}" != "none" ]]; then
  echo "this node is a ${virt} guest. a 64 KB kernel will not boot under a 4 KB hypervisor." >&2
  echo "stopped. page size stays ${pages}." >&2
  exit 1
fi

echo "installing linux-generic-64k (4 KB kernel stays on disk)"
sudo -n apt-get update
sudo -n apt-get install -y linux-generic-64k
write_order "generic-64k"
echo "64 KB kernel installed. 4 KB kernel is still installed."
echo "next: sudo reboot"
echo "after ssh is back: getconf PAGE_SIZE"
echo "65536 means it worked. then ./o g and ./o s before ./o 1"
echo "if ssh does not come back, use the Oracle console and boot the kernel that is not generic-64k"
echo "to switch back after a 4 KB boot: ./o 6 undo"
