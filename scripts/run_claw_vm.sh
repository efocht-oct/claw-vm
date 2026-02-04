#!/usr/bin/env bash
set -euo pipefail

# ===== Config =====
VM_DIR="${VM_DIR:-$PWD/ubuntu24-qemu}"
VM_NAME="${VM_NAME:-noble-node22}"
RAM_MB="${RAM_MB:-8192}"
CPUS="${CPUS:-4}"
DISK_GB="${DISK_GB:-30}"

# If you already have a Linux bridge (recommended for "same network as host"), set BRIDGE=br0
BRIDGE="${BRIDGE:-br0}"

# SSH port forwarding when using NAT fallback:
SSH_FWD_PORT="${SSH_FWD_PORT:-2222}"

# Ubuntu 24.04 cloud image URLs (no ISO install)
# Try the released image first, then fall back to the "current" stream.
BASE_IMG_URLS=(
  "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img"
  "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
)

BASE_IMG="$VM_DIR/ubuntu-24.04-server-cloudimg-amd64.img"
OVERLAY_IMG="$VM_DIR/${VM_NAME}.qcow2"
SEED_IMG="$VM_DIR/seed.iso"

# cloud-init default user in Ubuntu cloud images is typically "ubuntu"
VM_USER="${VM_USER:-ubuntu}"

# IMPORTANT: replace this key with YOUR public key for SSH access,
# or set SSH_PUBKEY env var.
SSH_PUBKEY="${SSH_PUBKEY:-$(test -f "$HOME/.ssh/id_rsa.pub" && cat "$HOME/.ssh/id_rsa.pub" || true)}"

if [[ -z "${SSH_PUBKEY}" ]]; then
  echo "ERROR: No SSH public key found. Set SSH_PUBKEY env var or create ~/.ssh/id_rsa.pub"
  exit 1
fi

# ===== Host deps check =====
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }

need_cmd qemu-system-x86_64
need_cmd qemu-img
need_cmd curl
need_cmd ip

# cloud-localds is provided by cloud-image-utils on many distros
if ! command -v cloud-localds >/dev/null 2>&1; then
  echo "Missing dependency: cloud-localds (often in package: cloud-image-utils)"
  echo "On Ubuntu/Debian host: sudo apt-get install -y cloud-image-utils"
  exit 1
fi

mkdir -p "$VM_DIR"

# ===== Download base image (no ISO install) =====
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

# ===== Create overlay disk =====
if [[ ! -f "$OVERLAY_IMG" ]]; then
  echo "Creating overlay disk: $OVERLAY_IMG (${DISK_GB}G)"
  qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$OVERLAY_IMG" "${DISK_GB}G"
else
  echo "Overlay disk already exists: $OVERLAY_IMG"
fi

# ===== Create cloud-init seed (installs packages on first boot) =====
USER_DATA="$VM_DIR/user-data"
META_DATA="$VM_DIR/meta-data"

cat >"$USER_DATA" <<'EOF'
#cloud-config
hostname: noble-node22
manage_etc_hosts: true

# Avoid tzdata / debconf prompts in non-interactive cloud-init
timezone: Etc/UTC

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, admin, sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - __SSH_PUBKEY__

package_update: true
package_upgrade: true

# Force non-interactive apt everywhere (prevents whiptail/debconf tty errors)
write_files:
  - path: /etc/apt/apt.conf.d/99noninteractive
    permissions: '0644'
    content: |
      Dpkg::Options {
        "--force-confdef";
        "--force-confold";
      };
      APT::Get::Assume-Yes "true";
      APT::Get::Quiet "true";
      Acquire::Retries "3";

packages:
  - git
  - build-essential
  - ca-certificates
  - curl
  - gpg
  - pkg-config
  - libvips-dev
  # Backstop in case anything tries to invoke debconf frontend
  - debconf
  - debconf-utils

runcmd:
  # Always run apt non-interactively in cloud-init
  - [ bash, -lc, "export DEBIAN_FRONTEND=noninteractive" ]

  # Add NodeSource repo for Node.js 22 (avoid running their setup script)
  - [ bash, -lc, "install -d -m 0755 /usr/share/keyrings" ]
  - [ bash, -lc, "curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg" ]
  - [ bash, -lc, "echo 'deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main' > /etc/apt/sources.list.d/nodesource.list" ]
  - [ bash, -lc, "apt-get update" ]
  - [ bash, -lc, "DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs" ]

  # Backstop: ensure npm exists (Ubuntu can separate it; NodeSource usually includes it)
  - [ bash, -lc, "command -v npm >/dev/null 2>&1 || (DEBIAN_FRONTEND=noninteractive apt-get install -y npm)" ]

  - [ bash, -lc, "node -v && npm -v" ]

  # Install openclaw (global) via npm
  - [ bash, -lc, "npm install -g openclaw@latest" ]
  - [ bash, -lc, "openclaw --version || true" ]

final_message: "Cloud-init complete. You can SSH to the VM user 'ubuntu'."
EOF

# Substitute runtime values safely
# (We used a single-quoted heredoc above so cloud-init YAML doesn't get mangled by bash)
sed -i \
  -e "s/^hostname: .*/hostname: ${VM_NAME}/" \
  -e "s/^instance-id: .*/instance-id: ${VM_NAME}-$(date +%s)/" \
  "$USER_DATA" 2>/dev/null || true

# Replace placeholders for user + key
# Note: escape slashes & ampersands for sed
esc_key="$(printf '%s' "$SSH_PUBKEY" | sed 's/[\/&]/\\&/g')"
sed -i \
  -e "s/^  - name: ubuntu$/  - name: ${VM_USER}/" \
  -e "s/__SSH_PUBKEY__/${esc_key}/" \
  "$USER_DATA"

cat >"$META_DATA" <<EOF
instance-id: ${VM_NAME}-$(date +%s)
local-hostname: ${VM_NAME}
EOF

echo "Creating seed image..."
cloud-localds -v "$SEED_IMG" "$USER_DATA" "$META_DATA"

# ===== Networking selection =====
NET_ARGS=()
MODE="nat"

if ip link show "$BRIDGE" >/dev/null 2>&1; then
  MODE="bridge"
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

# ===== Boot VM =====
echo "Starting VM..."
echo "Disk: $OVERLAY_IMG"
echo "Seed: $SEED_IMG"
echo "Networking mode: $MODE"
if [[ "$MODE" == "nat" ]]; then
  echo "SSH with: ssh -p ${SSH_FWD_PORT} ${VM_USER}@127.0.0.1"
fi

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
