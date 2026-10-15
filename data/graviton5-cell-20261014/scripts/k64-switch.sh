#!/bin/bash
# One-shot boot into the 64 KiB-page build of the SAME kernel version (6.17.0-1017-aws-64k). Falls back to 4k on the next plain reboot.
set -euo pipefail
note() { echo "$(date -u +%FT%TZ) $*" | sudo tee -a /etc/rlp/HOSTCHANGES >/dev/null; echo "$*"; }
V=6.17.0-1017-aws
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq linux-image-$V-64k linux-modules-$V-64k >/dev/null
grep -q '^GRUB_DEFAULT=saved' /etc/default/grub.d/99-rlp-bench.cfg || echo 'GRUB_DEFAULT=saved' | sudo tee -a /etc/default/grub.d/99-rlp-bench.cfg >/dev/null
sudo update-grub >/dev/null 2>&1
E4="Advanced options for Ubuntu>Ubuntu, with Linux $V"; E64="Advanced options for Ubuntu>Ubuntu, with Linux $V-64k"
sudo grep -q "menuentry 'Ubuntu, with Linux $V-64k'" /boot/grub/grub.cfg || { echo "64k entry missing"; exit 1; }
sudo grub-set-default "$E4"; sudo grub-reboot "$E64"
note "kernel: installed linux-image-$V-64k; GRUB_DEFAULT=saved (default=$V 4k); grub-reboot one-shot -> 64k"
sudo grub-editenv list
