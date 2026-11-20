#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SPEC="$ROOT/factory/amd64-vmware-io.json"
DATA_DIR="${TRY_FYDEOS_DATA:-$HOME/.local/share/Try FydeOS}"
IMAGE_DIR="$DATA_DIR/images"
VM_DIR="$DATA_DIR/VM/v1"
OVA="$IMAGE_DIR/fydeos.ova"

for command in curl python3 sha256sum qemu-img tar; do
  command -v "$command" >/dev/null || {
    echo "linux/prepare: missing dependency: $command (run make linux-install)" >&2
    exit 1
  }
done

mkdir -p "$IMAGE_DIR" "$VM_DIR"

mapfile -t image_info < <(python3 - "$SPEC" <<'PY'
import json
import sys
spec = json.load(open(sys.argv[1], encoding="utf-8"))
print(spec["image"]["url"])
print(spec["image"]["sha256"])
print(spec["diskBytes"])
PY
)

URL="${image_info[0]}"
SHA256="${image_info[1]}"
DISK_BYTES="${image_info[2]}"

if [[ ! -f "$OVA" ]]; then
  echo "Downloading FydeOS VMware image..."
  curl --fail --location --retry 3 --continue-at - --output "$OVA" "$URL"
fi

echo "Verifying FydeOS VMware image..."
ACTUAL="$(sha256sum "$OVA" | awk '{print $1}')"
if [[ "$ACTUAL" != "$SHA256" ]]; then
  echo "linux/prepare: SHA-256 mismatch" >&2
  echo "expected $SHA256" >&2
  echo "actual   $ACTUAL" >&2
  exit 1
fi

DISK="$VM_DIR/fydeos.raw"
if [[ ! -f "$DISK" ]]; then
  EXTRACT="$VM_DIR/ova"
  mkdir -p "$EXTRACT"
  tar -xf "$OVA" -C "$EXTRACT"
  VMDK="$(find "$EXTRACT" -type f -iname '*.vmdk' -print -quit)"
  if [[ -z "$VMDK" ]]; then
    echo "linux/prepare: no VMDK found in OVA" >&2
    exit 1
  fi
  echo "Converting FydeOS VMware disk..."
  qemu-img convert -p -f vmdk -O raw "$VMDK" "$DISK"
  truncate -s "$DISK_BYTES" "$DISK"
fi

cp_vars=""
for candidate in \
  /usr/share/OVMF/OVMF_VARS_4M.fd \
  /usr/share/OVMF/OVMF_VARS.fd \
  /usr/share/qemu/OVMF_VARS.fd \
  /usr/share/edk2/ovmf/OVMF_VARS.fd; do
  if [[ -f "$candidate" ]]; then cp_vars="$candidate"; break; fi
done
if [[ -z "$cp_vars" ]]; then
  echo "linux/prepare: OVMF variable store not found" >&2
  exit 1
fi
cp -n "$cp_vars" "$VM_DIR/OVMF_VARS.fd"

echo "Prepared FydeOS disk at $DISK"
