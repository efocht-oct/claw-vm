#!/usr/bin/env bash
set -euo pipefail

# Restore Hermes agent state from an encrypted GPG archive created by backup-hermes.sh.
# WARNING: This overwrites files under ~/.hermes, ~/.config/gh, ~/.ssh, ~/.vnc, etc.

ARCHIVE="${1:-}"
if [[ -z "$ARCHIVE" ]]; then
  echo "Usage: $0 /path/to/hermes-backup-*.tar.gpg"
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

if [[ -n "${RESTORE_GPG_PASSPHRASE:-}" ]]; then
  gpg --batch --yes --pinentry-mode loopback --passphrase "$RESTORE_GPG_PASSPHRASE" \
    --output "$plain" --decrypt "$ARCHIVE"
else
  gpg --output "$plain" --decrypt "$ARCHIVE"
fi

tar --xattrs --acls -xf "$plain"

echo "Restore complete."

# Post-restore environment fixes (idempotent)
mkdir -p "$HOME/.local/bin"

# Ensure ~/.local/bin is on PATH for login shells
if ! grep -q "^export PATH=\"\$HOME/.local/bin:" "$HOME/.profile" 2>/dev/null; then
  echo "export PATH=\"$HOME/.local/bin:$PATH\"" >> "$HOME/.profile"
fi

# Also ensure for interactive bash
if [[ -f "$HOME/.bashrc" ]] && ! grep -q "^export PATH=\"\$HOME/.local/bin:" "$HOME/.bashrc" 2>/dev/null; then
  echo "export PATH=\"$HOME/.local/bin:$PATH\"" >> "$HOME/.bashrc"
fi

# Ensure Linuxbrew is wired in (supports shared and per-user installs)
BREW_INIT='if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then\n  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"\nelif [ -x "$HOME/.linuxbrew/bin/brew" ]; then\n  eval "$( $HOME/.linuxbrew/bin/brew shellenv )"\nfi'
for f in "$HOME/.profile" "$HOME/.bashrc"; do
  [[ -f "$f" ]] || continue
  if ! grep -q "brew shellenv" "$f" 2>/dev/null; then
    printf "\n# Homebrew (Linuxbrew)\n%s\n" "$BREW_INIT" >> "$f"
  fi
done

# Recreate a Hermes launcher in ~/.local/bin (useful when npm global bin isn't on PATH)
cat >"$HOME/.local/bin/hermes" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec node "$HOME/.hermes/workspace/hermes-agent/dist/index.js" "$@"
EOF
chmod +x "$HOME/.local/bin/hermes"

echo "Post-restore fixes applied (~/.profile, ~/.bashrc, ~/.local/bin/hermes)."

echo "If Hermes is running, restart it after restore (depending on your install method)."
