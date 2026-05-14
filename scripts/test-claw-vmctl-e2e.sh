#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VMCTL="$SCRIPT_DIR/claw-vmctl"

BASE_DIR="${BASE_DIR:-$ROOT_DIR/.e2e-claw-vm}"
VM_ID="${VM_ID:-e2e}"
VM_NAME="${VM_NAME:-noble-claw-e2e}"
VM_USER="${VM_USER:-claw}"
SSH_PORT="${SSH_PORT:-2292}"
VNC_PORT="${VNC_PORT:-5992}"
BACKUP_OUT_DIR="${BACKUP_OUT_DIR:-$ROOT_DIR/.e2e-backups/$VM_ID}"
WAIT_SSH_SECONDS="${WAIT_SSH_SECONDS:-900}"
KEEP_ARTIFACTS="${KEEP_ARTIFACTS:-0}"
GPG_PASSPHRASE="${GPG_PASSPHRASE:-claw-e2e-passphrase}"

MARKER_FILE="/home/${VM_USER}/.hermes/e2e-restore-marker.txt"
MARKER_VALUE="e2e-marker-$(date -u +%Y%m%dT%H%M%SZ)"

log() {
  printf '[e2e] %s\n' "$*"
}

die() {
  printf '[e2e][ERROR] %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

vmctl() {
  "$VMCTL" "$@"
}

ssh_vm() {
  ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new "${VM_USER}@127.0.0.1" "$@"
}

wait_for_ssh() {
  local start now
  start="$(date +%s)"
  while true; do
    if ssh_vm "echo ok" >/dev/null 2>&1; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= WAIT_SSH_SECONDS )); then
      return 1
    fi
    sleep 5
  done
}

cleanup() {
  local rc="$?"
  set +e

  log "Cleanup: stopping VM if still running"
  vmctl stop "$VM_ID" --base-dir "$BASE_DIR" >/dev/null 2>&1 || true

  if [[ "$KEEP_ARTIFACTS" != "1" ]]; then
    log "Cleanup: removing test artifacts"
    rm -rf "$BASE_DIR" "$BACKUP_OUT_DIR"
  else
    log "KEEP_ARTIFACTS=1 set; preserving $BASE_DIR and $BACKUP_OUT_DIR"
  fi

  exit "$rc"
}

main() {
  trap cleanup EXIT

  need_cmd ssh
  need_cmd scp

  [[ -x "$VMCTL" ]] || die "claw-vmctl not executable: $VMCTL"

  log "Using BASE_DIR=$BASE_DIR VM_ID=$VM_ID SSH_PORT=$SSH_PORT VNC_PORT=$VNC_PORT"

  log "0) help"
  vmctl --help >/dev/null

  log "1) init"
  vmctl init "$VM_ID" \
    --base-dir "$BASE_DIR" \
    --name "$VM_NAME" \
    --vm-user "$VM_USER" \
    --ssh-port "$SSH_PORT" \
    --vnc-port "$VNC_PORT"

  log "2) list (pre-build)"
  vmctl list --base-dir "$BASE_DIR" | grep -q "${VM_ID}" || die "VM_ID not present in list output"

  log "3) build"
  vmctl build "$VM_ID" --base-dir "$BASE_DIR"

  log "4) start"
  vmctl start "$VM_ID" --base-dir "$BASE_DIR"

  log "5) status should be running"
  vmctl status "$VM_ID" --base-dir "$BASE_DIR" | grep -q "STATE         : running" || die "VM status is not running"

  log "6) wait for SSH readiness"
  wait_for_ssh || die "SSH did not become ready within ${WAIT_SSH_SECONDS}s"

  log "7) direct in-VM Hermes checks"
  ssh_vm "set -euo pipefail; command -v hermes; hermes --version; test -f \"\$HOME/.hermes/workspace/hermes-agent/dist/index.js\""

  log "8) create marker file for restore verification"
  ssh_vm "set -euo pipefail; mkdir -p \"\$(dirname '$MARKER_FILE')\"; printf '%s\n' '$MARKER_VALUE' > '$MARKER_FILE'"

  log "9) backup (downloads archive to host)"
  mkdir -p "$BACKUP_OUT_DIR"
  BACKUP_GPG_PASSPHRASE="$GPG_PASSPHRASE" vmctl backup "$VM_ID" --base-dir "$BASE_DIR" --out-dir "$BACKUP_OUT_DIR"

  local archive
  archive="$(ls -1 "$BACKUP_OUT_DIR"/hermes-backup-*.tar.gpg 2>/dev/null | sort | tail -n 1 || true)"
  [[ -n "$archive" && -f "$archive" ]] || die "backup archive not found in $BACKUP_OUT_DIR"

  log "10) mutate marker file before restore"
  ssh_vm "set -euo pipefail; printf '%s\n' 'modified-after-backup' > '$MARKER_FILE'"

  log "11) restore from host archive"
  RESTORE_GPG_PASSPHRASE="$GPG_PASSPHRASE" vmctl restore "$VM_ID" --base-dir "$BASE_DIR" "$archive"

  log "12) verify restored marker value"
  local restored
  restored="$(ssh_vm "cat '$MARKER_FILE'")"
  [[ "$restored" == "$MARKER_VALUE" ]] || die "marker mismatch after restore (got '$restored', expected '$MARKER_VALUE')"

  log "13) list + status after restore"
  vmctl list --base-dir "$BASE_DIR" | grep -q "${VM_ID}" || die "VM_ID missing from list after restore"
  vmctl status "$VM_ID" --base-dir "$BASE_DIR" | grep -q "STATE         : running" || die "VM stopped unexpectedly"

  log "14) stop"
  vmctl stop "$VM_ID" --base-dir "$BASE_DIR"
  vmctl status "$VM_ID" --base-dir "$BASE_DIR" | grep -q "STATE         : stopped" || die "VM did not stop"

  log "15) list after stop"
  vmctl list --base-dir "$BASE_DIR" | grep -q "${VM_ID}" || die "VM_ID missing from list after stop"

  log "E2E VM test passed"
}

main "$@"
