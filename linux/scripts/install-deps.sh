#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "linux/install-deps: x86-64 Linux is required" >&2
  exit 1
fi

if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y qemu-system-x86 qemu-utils ovmf xvfb x11vnc x11-utils mesa-utils curl ca-certificates tar python3
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y qemu-kvm qemu-img edk2-ovmf xorg-x11-server-Xvfb xorg-x11-utils x11vnc mesa-dri-drivers curl tar python3
else
  echo "linux/install-deps: install QEMU, OVMF, Xvfb, x11vnc and Docker Compose with your distribution package manager" >&2
  exit 1
fi
