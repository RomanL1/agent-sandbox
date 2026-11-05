#!/usr/bin/env bash
# Provision the sandbox VM: Claude Code, Codex, opencode, Copilot CLI, agy.
# Runs once as root inside a fresh Debian 13 VM; `./sandbox init` pipes it in.
set -euo pipefail

DEV=dev
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl git openssh-client gnupg nftables \
  ripgrep fd-find jq less vim-tiny procps xz-utils unzip \
  build-essential python3 python3-venv python3-pip
# Debian ships these under other names.
ln -sfn /usr/bin/fdfind /usr/local/bin/fd
ln -sfn /usr/bin/vim.tiny /usr/local/bin/vim

# GitHub CLI: agents lean on it for PRs and issues.
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list
apt-get update && apt-get install -y --no-install-recommends gh

# Node via nvm, system-wide, with its versioned bin dir on a stable path.
export HOME=/opt/node
mkdir -p "$HOME"
curl -fsSL -o /tmp/nvm-install.sh https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.8/install.sh
bash /tmp/nvm-install.sh
set +u; . "$HOME/.nvm/nvm.sh"; nvm install 26; set -u
ln -sfn "$NVM_BIN" /opt/node-bin
npm install -g --no-fund --no-audit @github/copilot
npm cache clean --force
export HOME=/root

# Block the VM from reaching the Mac and the LAN. QEMU user networking maps
# 10.0.2.2 to the Mac's localhost; 10.0.2.3 is its DNS forwarder. Replies to
# inbound ssh (which arrives from 10.0.2.2) stay allowed.
cat > /etc/nftables.conf <<'NFT'
#!/usr/sbin/nft -f
flush ruleset
table inet sandbox {
  chain out {
    type filter hook output priority 0; policy accept;
    ct state established,related accept
    oif lo accept
    ip daddr 10.0.2.3 accept
    ip6 daddr fec0::3 accept
    ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10 } reject
    ip6 daddr { fec0::/10, fc00::/7 } reject
  }
}
NFT
systemctl enable --now nftables

# Let the launcher forward API keys and git identity as ssh environment, so
# their values never appear on a command line.
cat > /etc/ssh/sshd_config.d/10-sandbox.conf <<'SSHD'
AcceptEnv ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL
AcceptEnv OPENAI_API_KEY OPENAI_BASE_URL GITHUB_TOKEN GH_TOKEN
AcceptEnv OPENCODE_API_KEY GEMINI_API_KEY HTTP_PROXY HTTPS_PROXY NO_PROXY
AcceptEnv SANDBOX_NO_BYPASS GIT_AUTHOR_* GIT_COMMITTER_*
SSHD
systemctl reload ssh

# PATH for every login shell, including the `bash -lc` the launcher runs.
cat > /etc/profile.d/10-sandbox-path.sh <<'PROFILE'
PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$HOME/.opencode/bin:$HOME/.antigravity/bin:/opt/node-bin:$PATH"
export PATH NODE_NO_WARNINGS=1 NPM_CONFIG_PREFIX="$HOME/.npm-global"
# Tools installed later register themselves here, so adding one is one line.
[ -r "$HOME/.sandbox-env" ] && . "$HOME/.sandbox-env"
PROFILE

# Agents launch with their permission prompts bypassed: the VM is the boundary.
# Functions, not aliases, so they also apply in non-interactive login shells.
# `command claude ...` reaches the raw binary.
cat > /etc/profile.d/20-agent-bypass.sh <<'PROFILE'
if [ -z "${SANDBOX_NO_BYPASS:-}" ]; then
  # Passing these flags twice is an error for some CLIs (codex rejects the
  # duplicate outright), so only add one the caller has not already supplied.
  _sb_has() { f=$1; shift; for a in "$@"; do [ "$a" = "$f" ] && return 0; done; return 1; }
  _sb_wrap() {
    bin=$1; flag=$2; shift 2
    if _sb_has "$flag" "$@"; then command "$bin" "$@"; else command "$bin" "$flag" "$@"; fi
  }
  claude()  { _sb_wrap claude  --dangerously-skip-permissions "$@"; }
  agy()     { _sb_wrap agy     --dangerously-skip-permissions "$@"; }
  codex()   { _sb_wrap codex   --dangerously-bypass-approvals-and-sandbox "$@"; }
  copilot() { _sb_wrap copilot --allow-all "$@"; }
  # opencode takes --auto on `run` and the TUI, not on other subcommands.
  opencode() {
    case "${1:-}" in
      run)
        shift                      # --auto is a flag of `run`, so it goes after it
        if _sb_has --auto "$@"; then command opencode run "$@";
        else command opencode run --auto "$@"; fi ;;
      ""|-*) _sb_wrap opencode --auto "$@" ;;
      *) command opencode "$@" ;;
    esac
  }
fi
PROFILE

# Agent CLIs from their official installers, as the agent user, so they live
# in its home and can update themselves.
su - "$DEV" -c '
  set -e
  curl -fsSL https://claude.ai/install.sh | bash
  curl -fsSL https://chatgpt.com/codex/install.sh | sh
  curl -fsSL https://opencode.ai/v2/install | bash
  # agy may not publish a Linux build; keep going either way.
  if curl -fsSL https://antigravity.google/cli/install.sh | bash; then
    echo "agy: installed"
  else
    echo "agy: installer failed on this platform; continuing without it"
  fi
'

echo "provision: done"
