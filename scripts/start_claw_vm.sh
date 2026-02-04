#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_common.sh"

ensure_host_deps

if [[ ! -f "$OVERLAY_IMG" || ! -f "$SEED_IMG" ]]; then
  echo "ERROR: VM artifacts not found in $VM_DIR"
  echo "Expected: $OVERLAY_IMG and $SEED_IMG"
  echo "Run: ./build_claw_vm.sh first"
  exit 1
fi

MODE="$(net_args)"
NET_ARGS=()

if [[ "$MODE" == "bridge" ]]; then
  echo "Bridge '$BRIDGE' found: using bridged networking."
  NET_ARGS=(
    -netdev "bridge,id=net0,br=${BRIDGE}"
    -device "virtio-net-pci,netdev=net0"
  )
else
  echo "Bridge '$BRIDGE' not found: using NAT (user-mode) with SSH port forward host:${SSH_FWD_PORT} -> guest:22"
  NET_ARGS=(
    -netdev "user,id=net0,hostfwd=tcp::${SSH_FWD_PORT}-:22"
    -device "virtio-net-pci,netdev=net0"
  )
fi

echo "Starting VM..."
echo "Disk: $OVERLAY_IMG"
echo "Seed: $SEED_IMG"
echo "Networking mode: $MODE"

if [[ "$MODE" == "nat" ]]; then
  print_nat_help
fi

echo "NOTE: This VM runs headless. VNC inside the VM is localhost-only (-localhost)."

exec qemu-system-x86_64 \
  -enable-kvm \
  -cpu host \
  -smp "$CPUS" \
  -m "$RAM_MB" \
  -machine q35 \
  -drive "file=${OVERLAY_IMG},if=virtio,cache=writeback,discard=unmap,format=qcow2" \
  -drive "file=${SEED_IMG},if=virtio,media=cdrom" \
  "${NET_ARGS[@]}" \
  -device virtio-rng-pci \
  -display none \
  -serial mon:stdio
