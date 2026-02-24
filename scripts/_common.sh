#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLAW_VM_DEFAULT_BASE_DIR="${HOME}/ubuntu24-qemu-claw"
BASE_IMG_FILENAME="ubuntu-24.04-server-cloudimg-amd64.img"
BASE_IMG_URLS=(
  "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img"
  "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
)

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1"
    exit 1
  }
}

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
}

resolve_base_dir() {
  local override="${1:-}"
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
    return
  fi
  if [[ -n "${CLAW_VM_BASE_DIR:-}" ]]; then
    printf '%s\n' "$CLAW_VM_BASE_DIR"
    return
  fi
  printf '%s\n' "$CLAW_VM_DEFAULT_BASE_DIR"
}

trim_ws() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

is_allowed_vm_env_key() {
  case "$1" in
    VM_ID|VM_NAME|VM_USER|RAM_MB|CPUS|DISK_GB|BRIDGE|SSH_FWD_PORT|QEMU_VNC_PORT|SSH_PUBKEY)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

parse_vm_env_line() {
  local line="$1"
  local out_key_var="$2"
  local out_val_var="$3"
  local key value

  line="${line%$'\r'}"
  if [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]]; then
    return 2
  fi

  if [[ ! "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
    return 1
  fi

  key="${BASH_REMATCH[2]}"
  value="$(trim_ws "${BASH_REMATCH[3]}")"

  if [[ "$value" =~ ^\"(.*)\"$ ]]; then
    value="${BASH_REMATCH[1]}"
  elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
    value="${BASH_REMATCH[1]}"
  else
    value="${value%%[[:space:]]#*}"
    value="$(trim_ws "$value")"
  fi

  printf -v "$out_key_var" '%s' "$key"
  printf -v "$out_val_var" '%s' "$value"
  return 0
}

validate_vm_id() {
  local vm_id="${1:-}"
  [[ -n "$vm_id" ]] || {
    echo "ERROR: vm-id must be provided"
    return 1
  }
  [[ "$vm_id" =~ ^[a-zA-Z0-9_-]+$ ]] || {
    echo "ERROR: vm-id '$vm_id' is invalid. Allowed: [a-zA-Z0-9_-]"
    return 1
  }
}

set_vm_paths() {
  local base_dir="$1"
  local vm_id="$2"

  BASE_DIR="$base_dir"
  VM_ID="$vm_id"

  BASE_IMG_DIR="$BASE_DIR/base"
  BASE_IMG="$BASE_IMG_DIR/$BASE_IMG_FILENAME"

  VM_DIR="$BASE_DIR/vms/$VM_ID"
  VM_ENV_FILE="$VM_DIR/.env"
  VM_DISK_IMG="$VM_DIR/disk.qcow2"
  VM_SEED_IMG="$VM_DIR/seed.iso"
  VM_USER_DATA="$VM_DIR/user-data"
  VM_META_DATA="$VM_DIR/meta-data"

  VM_RUNTIME_DIR="$VM_DIR/runtime"
  VM_LOG_DIR="$VM_DIR/logs"
  VM_PID_FILE="$VM_RUNTIME_DIR/qemu.pid"
  VM_QMP_SOCK="$VM_RUNTIME_DIR/qmp.sock"
  VM_QEMU_LOG="$VM_LOG_DIR/qemu.log"
  VM_SERIAL_LOG="$VM_LOG_DIR/serial.log"
}

ensure_vm_dirs() {
  mkdir -p "$BASE_IMG_DIR" "$VM_DIR" "$VM_RUNTIME_DIR" "$VM_LOG_DIR"
}

default_ssh_pubkey() {
  if [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then
    cat "$HOME/.ssh/id_rsa.pub"
    return
  fi
  if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
    cat "$HOME/.ssh/id_ed25519.pub"
    return
  fi
  true
}

load_vm_env() {
  local env_file="$1"
  local vm_id_fallback="$2"
  local line key value parse_rc
  local line_no=0

  if [[ ! -f "$env_file" ]]; then
    echo "ERROR: missing VM env file: $env_file"
    return 1
  fi

  VM_ID="$vm_id_fallback"
  VM_NAME="noble-claw-$VM_ID"
  VM_USER="claw"
  RAM_MB="4096"
  CPUS="2"
  DISK_GB="30"
  BRIDGE=""
  SSH_FWD_PORT="2222"
  QEMU_VNC_PORT="5901"
  SSH_PUBKEY=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    if parse_vm_env_line "$line" key value; then
      parse_rc=0
    else
      parse_rc=$?
    fi
    if [[ "$parse_rc" -eq 2 ]]; then
      continue
    fi
    if [[ "$parse_rc" -ne 0 ]]; then
      echo "ERROR: invalid line in VM env file at ${env_file}:${line_no}"
      return 1
    fi

    if ! is_allowed_vm_env_key "$key"; then
      echo "ERROR: unsupported key '$key' in VM env file at ${env_file}:${line_no}"
      return 1
    fi

    case "$key" in
      VM_ID) VM_ID="$value" ;;
      VM_NAME) VM_NAME="$value" ;;
      VM_USER) VM_USER="$value" ;;
      RAM_MB) RAM_MB="$value" ;;
      CPUS) CPUS="$value" ;;
      DISK_GB) DISK_GB="$value" ;;
      BRIDGE) BRIDGE="$value" ;;
      SSH_FWD_PORT) SSH_FWD_PORT="$value" ;;
      QEMU_VNC_PORT) QEMU_VNC_PORT="$value" ;;
      SSH_PUBKEY) SSH_PUBKEY="$value" ;;
    esac
  done < "$env_file"

  SSH_PUBKEY="${SSH_PUBKEY:-$(default_ssh_pubkey)}"
}

validate_int() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || {
    echo "ERROR: $name must be an integer (got '$value')"
    return 1
  }
}

validate_port() {
  local name="$1"
  local value="$2"
  validate_int "$name" "$value" || return 1
  (( value >= 1 && value <= 65535 )) || {
    echo "ERROR: $name must be in range 1..65535 (got '$value')"
    return 1
  }
}

validate_vm_config() {
  validate_vm_id "$VM_ID" || return 1
  [[ "$VM_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || {
    echo "ERROR: VM_NAME '$VM_NAME' is invalid for hostname usage"
    return 1
  }

  validate_int "RAM_MB" "$RAM_MB" || return 1
  validate_int "CPUS" "$CPUS" || return 1
  validate_int "DISK_GB" "$DISK_GB" || return 1
  validate_port "SSH_FWD_PORT" "$SSH_FWD_PORT" || return 1
  validate_port "QEMU_VNC_PORT" "$QEMU_VNC_PORT" || return 1

  (( QEMU_VNC_PORT >= 5900 )) || {
    echo "ERROR: QEMU_VNC_PORT must be >= 5900 (got '$QEMU_VNC_PORT')"
    return 1
  }

  if [[ -z "${SSH_PUBKEY}" ]]; then
    echo "ERROR: No SSH public key found. Set SSH_PUBKEY in VM env or create ~/.ssh/id_rsa.pub or ~/.ssh/id_ed25519.pub"
    return 1
  fi
}

ensure_base_image() {
  mkdir -p "$BASE_IMG_DIR"
  if [[ -f "$BASE_IMG" ]]; then
    echo "Base image already exists: $BASE_IMG"
    return
  fi

  echo "Downloading Ubuntu 24.04 cloud image to shared base: $BASE_IMG"
  local ok=0
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
}

ensure_overlay_image() {
  if [[ -f "$VM_DISK_IMG" ]]; then
    echo "Overlay disk already exists: $VM_DISK_IMG"
    return
  fi

  echo "Creating overlay disk: $VM_DISK_IMG (${DISK_GB}G)"
  qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$VM_DISK_IMG" "${DISK_GB}G"
}

write_cloud_init_seed() {
  cat >"$VM_USER_DATA" <<'EOF2'
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

  - path: /etc/profile.d/brew.sh
    permissions: '0644'
    content: |
      # Homebrew (Linuxbrew)
      if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
      elif [ -x /home/__VM_USER__/.linuxbrew/bin/brew ]; then
        eval "$(/home/__VM_USER__/.linuxbrew/bin/brew shellenv)"
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
  - chromium-browser
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

  - [ bash, -lc, "su - __VM_USER__ -c 'mkdir -p ~/.npm-global ~/.cache/npm ~/.config ~/.local/bin'" ]
  - [ bash, -lc, "su - __VM_USER__ -c 'set -euo pipefail; npm config set prefix \"$HOME/.npm-global\"'" ]
  - [ bash, -lc, "su - __VM_USER__ -c 'grep -q \"$HOME/.local/bin\" ~/.profile 2>/dev/null || echo \"export PATH=\\\"$HOME/.local/bin:$PATH\\\"\" >> ~/.profile'" ]
  - [ bash, -lc, "su - __VM_USER__ -c 'grep -q \"$HOME/.npm-global/bin\" ~/.profile 2>/dev/null || echo \"export PATH=\\\"$HOME/.npm-global/bin:$PATH\\\"\" >> ~/.profile'" ]

  - [ bash, -lc, "curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o /tmp/brew-install.sh" ]
  - [ bash, -lc, "chmod +x /tmp/brew-install.sh" ]
  - [ bash, -lc, "su - __VM_USER__ -c 'set -euo pipefail; if [ ! -x ~/.linuxbrew/bin/brew ]; then NONINTERACTIVE=1 /bin/bash /tmp/brew-install.sh; fi'" ]
  - [ bash, -lc, "su - __VM_USER__ -c 'set -euo pipefail; $HOME/.linuxbrew/bin/brew --version || true'" ]

  - [ bash, -lc, "su - __VM_USER__ -c 'set -euo pipefail; source ~/.profile; mkdir -p ~/.openclaw/workspace; cd ~/.openclaw/workspace; if [ ! -d openclaw/.git ]; then git clone --depth 1 --branch stable https://github.com/openclaw/openclaw.git; fi; cd openclaw; npm install; npm run build'" ]
  - [ bash, -lc, "su - __VM_USER__ -c 'set -euo pipefail; source ~/.profile; cd ~/.openclaw/workspace/openclaw; npm install -g .; openclaw --version || true'" ]

final_message: "Cloud-init complete. SSH to '__VM_USER__' with your configured forwarded SSH port."
EOF2

  local esc_key
  esc_key="$(printf '%s' "$SSH_PUBKEY" | sed 's/[\/&]/\\&/g')"

  sed -i \
    -e "s/__VM_NAME__/${VM_NAME}/g" \
    -e "s/__VM_USER__/${VM_USER}/g" \
    -e "s/__SSH_PUBKEY__/${esc_key}/g" \
    "$VM_USER_DATA"

  cat >"$VM_META_DATA" <<EOF2
instance-id: ${VM_NAME}-$(date +%s)
local-hostname: ${VM_NAME}
EOF2

  echo "Creating seed image: $VM_SEED_IMG"
  cloud-localds -v "$VM_SEED_IMG" "$VM_USER_DATA" "$VM_META_DATA"
}

net_mode() {
  if [[ -n "$BRIDGE" ]] && ip link show "$BRIDGE" >/dev/null 2>&1; then
    echo "bridge"
    return
  fi
  echo "nat"
}

qemu_vnc_display() {
  echo "$((QEMU_VNC_PORT - 5900))"
}

is_vm_running() {
  if [[ -f "$VM_PID_FILE" ]]; then
    local pid
    pid="$(cat "$VM_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

cleanup_runtime_files() {
  rm -f "$VM_PID_FILE"
  [[ -S "$VM_QMP_SOCK" ]] && rm -f "$VM_QMP_SOCK"
}

env_get() {
  local env_file="$1"
  local key="$2"
  local line parsed_key parsed_value parse_rc
  local line_no=0
  local value=""

  if [[ ! -f "$env_file" ]]; then
    return 1
  fi

  is_allowed_vm_env_key "$key" || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    if parse_vm_env_line "$line" parsed_key parsed_value; then
      parse_rc=0
    else
      parse_rc=$?
    fi
    if [[ "$parse_rc" -eq 2 ]]; then
      continue
    fi
    if [[ "$parse_rc" -ne 0 ]]; then
      echo "ERROR: invalid line in VM env file at ${env_file}:${line_no}" >&2
      return 1
    fi

    if ! is_allowed_vm_env_key "$parsed_key"; then
      echo "ERROR: unsupported key '$parsed_key' in VM env file at ${env_file}:${line_no}" >&2
      return 1
    fi

    if [[ "$parsed_key" == "$key" ]]; then
      value="$parsed_value"
    fi
  done < "$env_file"

  printf '%s' "$value"
}
