#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_common.sh"

ensure_host_deps

echo "VM build/config"
echo "  VM_DIR   : $VM_DIR"
echo "  VM_NAME  : $VM_NAME"
echo "  VM_USER  : $VM_USER"
echo "  RAM_MB   : $RAM_MB"
echo "  CPUS     : $CPUS"
echo "  DISK_GB  : $DISK_GB"

# Download base image
if [[ ! -f "$BASE_IMG" ]]; then
  echo "Downloading Ubuntu 24.04 cloud image..."
  ok=0
  for u in "${BASE_IMG_URLS[@]}"; do
    echo "  trying: $u"
    if curl -fL --retry 3 --retry-delay 2 -o "$BASE_IMG" "$u"; then
      ok=1
      break
    fi
  done
  if [[ "$ok" -ne 1 ]]; then
    echo "ERROR: failed to download from all known URLs"
    exit 1
  fi
else
  echo "Base image already exists: $BASE_IMG"
fi

# Create overlay
if [[ ! -f "$OVERLAY_IMG" ]]; then
  echo "Creating overlay disk: $OVERLAY_IMG (${DISK_GB}G)"
  qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$OVERLAY_IMG" "${DISK_GB}G"
else
  echo "Overlay disk already exists: $OVERLAY_IMG"
fi

# Create seed
write_cloud_init_seed

echo "Build complete. Next: ./start_claw_vm.sh"
