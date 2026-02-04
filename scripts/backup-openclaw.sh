#!/usr/bin/env bash
set -euo pipefail

# Backup OpenClaw state INCLUDING SECRETS.
# Produces an encrypted archive using GPG symmetric encryption.

OUT_DIR="${OUT_DIR:-$PWD/backups}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo host)"

PLAIN_TAR="$OUT_DIR/openclaw-backup-${HOSTNAME_SHORT}-${STAMP}.tar"
ENC_TAR="$PLAIN_TAR.gpg"

mkdir -p "$OUT_DIR"

# What we back up:
# - ~/.openclaw (agent state, memory, sessions, config)
# - ~/.config/gh (GitHub CLI auth)
# - ~/.config/systemd/user (user services)
# - ~/.ssh (git/ssh keys)  [highly sensitive]
# - ~/.vnc (VNC password + config) [sensitive]

INCLUDE_PATHS=(
  "$HOME/.openclaw"
  "$HOME/.config/gh"
  "$HOME/.config/systemd/user"
  "$HOME/.ssh"
  "$HOME/.vnc"
)

# Filter to only existing paths
EXISTING=()
for p in "${INCLUDE_PATHS[@]}"; do
  if [[ -e "$p" ]]; then
    EXISTING+=("$p")
  fi
done

if [[ ${#EXISTING[@]} -eq 0 ]]; then
  echo "Nothing to back up (none of the expected directories exist)."
  exit 1
fi

echo "Creating tar: $PLAIN_TAR"
# Use --absolute-names so restore can place files correctly.
# Exclude a few obvious bulky logs/caches (safe to regenerate).
tar \
  --absolute-names \
  --xattrs \
  --acls \
  --exclude='*/node_modules' \
  --exclude='*/.cache/*' \
  --exclude='*/logs/*' \
  -cf "$PLAIN_TAR" \
  "${EXISTING[@]}"

echo "Encrypting with GPG (symmetric). Output: $ENC_TAR"
# Prompts for passphrase interactively.
gpg --symmetric --cipher-algo AES256 --output "$ENC_TAR" "$PLAIN_TAR"

# Remove plaintext tar after encryption
rm -f "$PLAIN_TAR"

echo "Done. Encrypted backup: $ENC_TAR"
