#!/usr/bin/env bash
set -euo pipefail

# Restore OpenClaw state from an encrypted GPG archive created by backup-openclaw.sh.
# WARNING: This overwrites files under ~/.openclaw, ~/.config/gh, ~/.ssh, ~/.vnc, etc.

ARCHIVE="${1:-}"
if [[ -z "$ARCHIVE" ]]; then
  echo "Usage: $0 /path/to/openclaw-backup-*.tar.gpg"
  exit 1
fi

if [[ ! -f "$ARCHIVE" ]]; then
  echo "ERROR: archive not found: $ARCHIVE"
  exit 1
fi

echo "Decrypting and extracting: $ARCHIVE"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

plain="$tmpdir/restore.tar"

gpg --output "$plain" --decrypt "$ARCHIVE"

tar --xattrs --acls -xf "$plain"

echo "Restore complete."

echo "If OpenClaw is running, restart it after restore (depending on your install method)."
