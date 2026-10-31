# Agentic dev sandbox: Claude Code, Codex, opencode, Copilot CLI.
# Portable across podman and docker.
ARG BASE=docker.io/library/debian:trixie-slim
FROM ${BASE}

ARG USER=dev
ARG UID=1000
ARG GID=1000

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-client gnupg \
      ripgrep fd-find jq less vim-tiny procps xz-utils unzip \
      build-essential python3 python3-venv python3-pip \
 && rm -rf /var/lib/apt/lists/*

# GitHub CLI: agents lean on it for PRs and issues.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# Node via nvm. Keep its versioned bin directory on a stable global path.
RUN set -eux; \
    export HOME=/opt/node; \
    mkdir -p "$HOME"; \
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.8/install.sh | bash; \
    . "$HOME/.nvm/nvm.sh"; \
    nvm install 26; \
    ln -s "$NVM_BIN" /opt/node-bin

ENV PATH=/opt/node-bin:$PATH

# Agent CLIs via their official installers. They install into $HOME/.local/bin,
# but /home/dev is a runtime volume that would mask anything placed there at
# build time, so install under a staging HOME and link the binaries into
# /usr/local/bin. At runtime HOME is /home/dev again, so each agent keeps its
# config and logins on the persistent volume.
ENV AGENT_HOME=/opt/agents
RUN set -eux; mkdir -p "$AGENT_HOME"; \
    HOME="$AGENT_HOME" bash -c 'curl -fsSL https://claude.ai/install.sh | bash'; \
    HOME="$AGENT_HOME" bash -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh'; \
    HOME="$AGENT_HOME" bash -c 'curl -fsSL https://opencode.ai/install | bash'; \
    npm install -g --no-fund --no-audit @github/copilot; \
    npm cache clean --force

# agy (Google Antigravity). Its installer may not publish a Linux build; keep
# the image buildable either way and report the outcome at build time.
RUN set -eu; \
    if HOME="$AGENT_HOME" bash -c 'curl -fsSL https://antigravity.google/cli/install.sh | bash'; then \
      echo "agy: installed"; \
    else \
      echo "agy: installer failed on this platform; continuing without it"; \
    fi

# Link every staged binary onto the default PATH.
RUN set -eux; \
    for d in "$AGENT_HOME"/.local/bin "$AGENT_HOME"/.opencode/bin "$AGENT_HOME"/.antigravity/bin; do \
      [ -d "$d" ] || continue; \
      for f in "$d"/*; do \
        [ -x "$f" ] || continue; \
        ln -sfn "$f" "/usr/local/bin/$(basename "$f")"; \
      done; \
    done; \
    chmod -R a+rX "$AGENT_HOME"; \
    ls -l /usr/local/bin

RUN groupadd -g "${GID}" "${USER}" \
 && useradd -m -u "${UID}" -g "${GID}" -s /bin/bash "${USER}"

# Keep user-level tools and the nvm-installed Node runtime available.
ENV PATH=/home/dev/.npm-global/bin:/home/dev/.local/bin:/opt/node-bin:$PATH \
    NODE_NO_WARNINGS=1

# A login shell reruns /etc/profile, which resets PATH; restore the required
# bin dirs for interactive and `bash -l` sessions.
RUN printf '%s\n' \
      'PATH="/home/dev/.npm-global/bin:/home/dev/.local/bin:/opt/node-bin:$PATH"' \
      'export PATH' \
      '# User-level tools installed at runtime register themselves here (it lives' \
      '# on the persistent home volume), so adding one never needs a rebuild.' \
      '[ -r /home/dev/.sandbox-env ] && . /home/dev/.sandbox-env' \
      > /etc/profile.d/10-sandbox-path.sh

# Shell functions so agents started from an interactive sandbox shell get the
# same bypass as `./sandbox <agent>`. Functions, not aliases, so they also apply
# in non-interactive login shells. `command claude ...` reaches the raw binary.
RUN cat > /etc/profile.d/20-agent-bypass.sh <<'PROFILE'
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
  # opencode only accepts --auto on `run`; its TUI has no bypass flag.
  opencode() {
    if [ "${1:-}" != run ]; then command opencode "$@"; return; fi
    shift                          # --auto is a flag of `run`, so it goes after it
    if _sb_has --auto "$@"; then command opencode run "$@";
    else command opencode run --auto "$@"; fi
  }
fi
PROFILE

USER ${USER}
WORKDIR /workspace
# Start every command through a login shell so directly exec'd agents see the
# same environment as `./sandbox shell`, including ~/.sandbox-env. `exec` skips
# the bypass functions above, so the launcher's own flags are not doubled.
ENTRYPOINT ["bash", "-lc", "exec \"$@\"", "--"]
CMD ["bash", "-l"]
