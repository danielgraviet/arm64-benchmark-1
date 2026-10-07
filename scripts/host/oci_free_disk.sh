#!/usr/bin/env bash
# Show what filled the disk and delete the kernel source tree.
# ./o k already installed the Image under /var/lib/rlp/kernel.
# The linux source in ~/erofs-poc is only needed to compile that Image.
#
# Typed: ./o x
set -euo pipefail

echo "=== disk ==="
df -h / /var /home /scratch /var/lib/docker 2>/dev/null || df -h /

echo "=== big dirs ==="
du -sh \
  "${HOME}/erofs-poc" \
  /var/lib/rlp \
  /scratch \
  /var/lib/docker \
  "${HOME}/rlp" \
  2>/dev/null || true

if [[ -d "${HOME}/erofs-poc" ]]; then
  echo "removing ${HOME}/erofs-poc (kernel source, Image already installed)"
  rm -rf "${HOME}/erofs-poc"
fi

echo "=== disk after ==="
df -h /
