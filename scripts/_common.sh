#!/usr/bin/env bash
set -euo pipefail

# Load configuration from .env if present (in the same directory as this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# Defaults
VM_DIR="${VM_DIR:-$PWD/ubuntu24-qemu}"
VM_NAME="${VM_NAME:-noble-claw}"
RAM_MB="${RAM_MB:-8192}"
CPUS="${CPUS:-4}"
DISK_GB="${DISK_GB:-30}"
BRIDGE="${BRIDGE:-br0}"
SSH_FWD_PORT="${SSH_FWD_PORT:-2222}"
VM_USER="${VM_USER:-claw}"

BASE_IMG_URLS=(
  "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img"
  "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
)

BASE_IMG="$VM_DIR/ubuntu-24.04-server-cloudimg-amd64.img"
OVERLAY_IMG="$VM_DIR/${VM_NAME}.qcow2"
SEED_IMG="$VM_DIR/seed.iso"

SSH_PUBKEY="${SSH_PUBKEY:-$(test -f "$HOME/.ssh/id_rsa.pub" && cat "$HOME/.ssh/id_rsa.pub" || true)}"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }

ensure_host_deps() {
  need_cmd qemu-system-x86_64
  need_cmd qemu-img
  need_cmd curl
  need_cmd ip

  if ! command -v cloud-localds >/dev/null 2>&1; then
    echo "Missing dependency: cloud-localds (often in package: cloud-image-utils)"
    echo "On Ubuntu/Debian host: sudo apt-get install -y cloud-image-utils"
    exit 1
  fi

  if [[ -z "${SSH_PUBKEY}" ]]; then
    echo "ERROR: No SSH public key found. Set SSH_PUBKEY env var or create ~/.ssh/id_rsa.pub"
    exit 1
  fi

  mkdir -p "$VM_DIR"
}

write_cloud_init_seed() {
  local user_data meta_data
  user_data="$VM_DIR/user-data"
  meta_data="$VM_DIR/meta-data"

  cat >"$user_data" <<'EOF'
#cloud-config
hostname: __VM_NAME__
manage_etc_hosts: true

timezone: Etc/UTC

users:
  - name: __VM_USER__
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, admin, sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - __SSH_PUBKEY__

package_update: true
package_upgrade: true

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

  # Make Homebrew available on PATH for the default user
  - path: /etc/profile.d/brew.sh
    permissions: '0644'
    content: |
      # Homebrew (Linuxbrew)
      if [ -x /home/__VM_USER__/.linuxbrew/bin/brew ]; then
        export PATH="/home/__VM_USER__/.linuxbrew/bin:/home/__VM_USER__/.linuxbrew/sbin:$PATH"
      fi

packages:
  - git
  - build-essential
  - ca-certificates
  - curl
  - gpg
  - pkg-config
  - libvips-dev
  - debconf
  - debconf-utils
  - xfce4
  - xfce4-goodies
  - dbus-x11
  - tigervnc-standalone-server
  - tigervnc-common
  - chromium-browser

  # Homebrew prerequisites
  - file
  - procps
  - locales
  - tzdata

runcmd:
  - [ bash, -lc, "export DEBIAN_FRONTEND=noninteractive" ]

  - [ bash, -lc, "install -d -m 0755 /usr/share/keyrings" ]
  - [ bash, -lc, "curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg" ]
  - [ bash, -lc, "echo 'deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main' > /etc/apt/sources.list.d/nodesource.list" ]
  - [ bash, -lc, "apt-get update" ]
  - [ bash, -lc, "DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs" ]
  - [ bash, -lc, "command -v npm >/dev/null 2>&1 || (DEBIAN_FRONTEND=noninteractive apt-get install -y npm)" ]
  - [ bash, -lc, "node -v && npm -v" ]

  - [ bash, -lc, "su - __VM_USER__ -c 'mkdir -p ~/.npm-global ~/.cache/npm ~/.config'" ]
  - [ bash, -lc, "su - __VM_USER__ -c 'grep -q NPM_CONFIG_PREFIX ~/.profile 2>/dev/null || { echo \"export NPM_CONFIG_PREFIX=\\\"$HOME/.npm-global\\\"\" >> ~/.profile; echo \"export PATH=\\\"$HOME/.npm-global/bin:$PATH\\\"\" >> ~/.profile; }'" ]

  # ---- Homebrew (Linuxbrew) in user HOME ----
  # NOTE: The previous implementation had quoting issues that could break cloud-init.
  # We download the installer as root and execute it as the target user.
  - [ bash, -lc, "curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o /tmp/brew-install.sh" ]
  - [ bash, -lc, "chmod +x /tmp/brew-install.sh" ]
  - [ bash, -lc, "su - __VM_USER__ -c 'set -euo pipefail; if [ ! -x ~/.linuxbrew/bin/brew ]; then NONINTERACTIVE=1 /bin/bash /tmp/brew-install.sh; fi'" ]
  - [ bash, -lc, "su - __VM_USER__ -c 'set -euo pipefail; $HOME/.linuxbrew/bin/brew --version || true'" ]

  - [ bash, -lc, "su - __VM_USER__ -c 'set -euo pipefail; source ~/.profile; mkdir -p ~/.openclaw/workspace; cd ~/.openclaw/workspace; if [ ! -d openclaw/.git ]; then git clone --depth 1 --branch stable https://github.com/openclaw/openclaw.git; fi; cd openclaw; npm install; npm run build'" ]
  - [ bash, -lc, "su - __VM_USER__ -c 'set -euo pipefail; source ~/.profile; cd ~/.openclaw/workspace/openclaw; npm install -g .; openclaw --version || true'" ]

  - [ bash, -lc, "su - __VM_USER__ -c 'mkdir -p ~/.vnc ~/.config/systemd/user'" ]
  - [ bash, -lc, "su - __VM_USER__ -c 'cat > ~/.vnc/xstartup <<\\\"XS\\\"\n#!/bin/sh\nunset SESSION_MANAGER\nunset DBUS_SESSION_BUS_ADDRESS\nexec startxfce4\nXS\nchmod +x ~/.vnc/xstartup'" ]
  - [ bash, -lc, "su - __VM_USER__ -c 'cat > ~/.config/systemd/user/vncserver@.service <<\\\"UNIT\\\"\n[Unit]\nDescription=TigerVNC server on display %i\nAfter=network.target\n\n[Service]\nType=forking\nExecStart=/usr/bin/vncserver :%i -localhost -geometry 1920x1080 -depth 24\nExecStop=/usr/bin/vncserver -kill :%i\n\n[Install]\nWantedBy=default.target\nUNIT'" ]
  - [ bash, -lc, "loginctl enable-linger __VM_USER__" ]
  - [ bash, -lc, "su - __VM_USER__ -c 'systemctl --user daemon-reload'" ]
  - [ bash, -lc, "su - __VM_USER__ -c 'systemctl --user enable vncserver@1.service'" ]

final_message: "Cloud-init complete. SSH to the VM user '__VM_USER__'. Then run: vncpasswd && systemctl --user start vncserver@1"
EOF

  local esc_key
  esc_key="$(printf '%s' "$SSH_PUBKEY" | sed 's/[\/&]/\\&/g')"

  sed -i \
    -e "s/__VM_NAME__/${VM_NAME}/g" \
    -e "s/__VM_USER__/${VM_USER}/g" \
    -e "s/__SSH_PUBKEY__/${esc_key}/g" \
    "$user_data"

  cat >"$meta_data" <<EOF
instance-id: ${VM_NAME}-$(date +%s)
local-hostname: ${VM_NAME}
EOF

  echo "Creating seed image..."
  cloud-localds -v "$SEED_IMG" "$user_data" "$meta_data"
}

net_args() {
  if ip link show "$BRIDGE" >/dev/null 2>&1; then
    echo "bridge"
  else
    echo "nat"
  fi
}

print_nat_help() {
  cat <<EOF
SSH with: ssh -p ${SSH_FWD_PORT} ${VM_USER}@127.0.0.1
After setting VNC password inside VM, tunnel VNC with:
  ssh -L 5901:127.0.0.1:5901 -p ${SSH_FWD_PORT} ${VM_USER}@127.0.0.1
Then connect your VNC client to: 127.0.0.1:5901
EOF
}
