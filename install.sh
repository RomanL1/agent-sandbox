#!/usr/bin/env bash
# One-command installer for agent-sandbox (macOS, Apple Silicon):
#   curl -fsSL https://raw.githubusercontent.com/RomanL1/agent-sandbox/main/install.sh | bash
# Clones the repo, links `sandbox` onto PATH, then creates the VM. Safe to rerun:
# it updates the checkout and finishes an init that was cut short.
#
# Uninstall (stops the VM, deletes the checkout, VM disk and Debian image):
#   curl -fsSL https://raw.githubusercontent.com/RomanL1/agent-sandbox/main/install.sh | bash -s -- --uninstall
set -euo pipefail

REPO="${SANDBOX_REPO:-https://github.com/RomanL1/agent-sandbox.git}"
BRANCH="${SANDBOX_BRANCH:-main}"
DEST="${SANDBOX_HOME:-$HOME/.agent-sandbox}"
BIN_DIR="${SANDBOX_BIN_DIR:-$HOME/.local/bin}"
VM_DIR="${SANDBOX_VM_DIR:-$DEST/vm}"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "install: $*" >&2; exit 1; }

# stdin is the script itself under `curl | bash`, so ask on the terminal.
confirm() {
  local ans
  printf '%s [y/N] ' "$1"
  read -r ans </dev/tty || ans=
  [ "$ans" = y ]
}

uninstall() {
  [ -d "$DEST" ] || [ -d "$VM_DIR" ] || [ -L "$BIN_DIR/sandbox" ] || die "nothing installed at $DEST"
  echo "This deletes:"
  echo "  $DEST        (checkout)"
  echo "  $VM_DIR      (VM disk, Debian image, ssh key; all logins in the VM)"
  echo "  $BIN_DIR/sandbox"
  confirm "Continue?" || die "aborted"

  [ -x "$DEST/sandbox" ] && SANDBOX_VM_DIR="$VM_DIR" "$DEST/sandbox" stop 2>/dev/null || true

  # Your projects may live in workspace/; never delete them without asking.
  local ws="$DEST/workspace"
  if [ -d "$ws" ] && [ -n "$(ls -A "$ws" | grep -vx .gitkeep)" ]; then
    if ! confirm "$ws has files. Delete them too?"; then
      local keep="$HOME/agent-sandbox-workspace"
      [ -e "$keep" ] && keep="$keep-$(date +%Y%m%d%H%M%S)"
      mv "$ws" "$keep"
      say "Moved workspace to $keep"
    fi
  fi

  [ "$(readlink "$BIN_DIR/sandbox" 2>/dev/null)" = "$DEST/sandbox" ] && rm -f "$BIN_DIR/sandbox"
  rm -rf "$VM_DIR" "$DEST"
  say "Uninstalled. qemu stays installed; remove it with: brew uninstall qemu"
}

case "${1:-}" in
  --uninstall) uninstall; exit 0 ;;
  "") ;;
  *) die "unknown option '$1' (only --uninstall)" ;;
esac

[ "$(uname -s)" = Darwin ] || die "macOS only"
[ "$(uname -m)" = arm64 ] || die "Apple Silicon (arm64) only"
command -v git >/dev/null || die "git missing: run 'xcode-select --install'"
command -v brew >/dev/null || command -v qemu-system-aarch64 >/dev/null \
  || die "Homebrew missing: install it from https://brew.sh, then rerun"

if [ -d "$DEST/.git" ]; then
  say "Updating $DEST"
  git -C "$DEST" fetch --quiet origin "$BRANCH"
  git -C "$DEST" checkout --quiet "$BRANCH"
  git -C "$DEST" merge --ff-only --quiet "origin/$BRANCH"
elif [ -e "$DEST" ]; then
  die "$DEST exists and is not a git checkout; move it or set SANDBOX_HOME"
else
  say "Cloning into $DEST"
  git clone --quiet --branch "$BRANCH" "$REPO" "$DEST"
fi

mkdir -p "$BIN_DIR"
ln -sfn "$DEST/sandbox" "$BIN_DIR/sandbox"
say "Linked $BIN_DIR/sandbox"

# </dev/null: under `curl | bash` stdin is this script, and ssh inside init
# would otherwise read (and swallow) the rest of it.
if [ -z "${SANDBOX_SKIP_INIT:-}" ]; then
  if [ ! -f "$VM_DIR/disk.qcow2" ]; then
    say "Creating the VM (several minutes)"
    "$DEST/sandbox" init </dev/null
  elif [ ! -f "$VM_DIR/provisioned" ]; then
    say "VM exists but was never fully provisioned; provisioning"
    "$DEST/sandbox" provision </dev/null
  else
    say "VM already provisioned"
  fi
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo
     echo "Add $BIN_DIR to PATH, e.g.:"
     echo "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc && exec zsh" ;;
esac

echo
say "Installed $("$DEST/sandbox" version)"
say "Try: sandbox claude   (workspace: $DEST/workspace, or sandbox -w DIR ...)"
