# agent-sandbox

Rootless container sandbox for agentic development. Claude Code, Codex,
opencode, GitHub Copilot CLI and Antigravity (`agy`) run inside a container with
no access to your host credentials or files outside `workspace/`.

Podman-first, Docker-compatible.

## Quick start

```sh
./sandbox build
./sandbox claude          # or: codex / opencode / copilot / agy
```

Each agent logs in inside the sandbox on first run; logins persist in a named
volume, so `--rm` containers stay stateless without forcing you to re-auth.

Agents launch with their permission prompts **bypassed** — the container is the
security boundary, so approving each edit and command inside it buys nothing.
The same wrappers apply to agents started from `./sandbox shell`. Set
`SANDBOX_NO_BYPASS=1` to restore the prompts, or call `command claude ...`
inside the sandbox to reach the unwrapped binary.

| Agent | Flag applied |
|---|---|
| `claude` | `--dangerously-skip-permissions` |
| `agy` | `--dangerously-skip-permissions` |
| `codex` | `--dangerously-bypass-approvals-and-sandbox` |
| `copilot` | `--allow-all` |
| `opencode` | `--auto`, on `opencode run` only — the TUI has no bypass flag |

A flag you pass yourself is not duplicated (codex rejects the repeat).

Put code in `workspace/` — it is bind-mounted read-write at `/workspace`.

## Commands

| Command | Effect |
|---|---|
| `build [args...]` | Build the image; extra args pass through to the engine |
| `claude` / `codex` / `opencode` / `copilot` / `agy` | Run that agent with permissions bypassed, args forwarded |
| `shell` | Interactive shell |
| `run <cmd...>` | One command in an ephemeral container |
| `up` / `exec <cmd...>` / `down` / `ps` | Long-lived container lifecycle |
| `import-creds [name...]` | Copy host agent logins into the sandbox volume |
| `reset-home` | Delete the volume, dropping all sandbox logins |
| `info` | Engine, rootless status, resolved settings |

## What is in the image

| | |
|---|---|
| Agents | `claude`, `codex`, `opencode`, `copilot`, `agy` |
| Toolchain | Node 22, Python 3.13, build-essential |
| Dev tools | `git`, `gh`, `ripgrep`, `fd`, `jq`, `curl`, `vim` |

Agents come from their official installers, which target `$HOME/.local/bin`.
Since `/home/dev` is a runtime volume that would mask a build-time install, the
image installs them under `/opt/agents` and links them onto `PATH`. At runtime
`HOME` is `/home/dev` again, so each agent writes its config to the volume.

Claude Code relocates itself to `~/.local/share/claude` on first run and
self-updates from there, so its version tracks the volume rather than the image
once the volume exists; `./sandbox reset-home` returns it to the image version.

## Configuration

| Variable | Default | Notes |
|---|---|---|
| `SANDBOX_ENGINE` | autodetect | `podman` preferred, else `docker` |
| `SANDBOX_IMAGE` | `agent-sandbox:dev` | |
| `SANDBOX_NAME` | `agent-sandbox` | Long-lived container name |
| `SANDBOX_WORKSPACE` | `./workspace` | Host dir mounted at `/workspace` |
| `SANDBOX_HOME_VOLUME` | `agent-sandbox-home` | Persistent `/home/dev` |
| `SANDBOX_NET` | `bridge` | `none` blocks all network |
| `SANDBOX_PORTS` | none | e.g. `"8080:8080 5173:5173"` |
| `SANDBOX_MEMORY` | `8g` | |
| `SANDBOX_HOST_HOME` | `$HOME` | Source home for `import-creds` |
| `SANDBOX_NO_BYPASS` | unset | Set to `1` to keep agent permission prompts |

API keys present in the calling shell are forwarded (`ANTHROPIC_API_KEY`,
`OPENAI_API_KEY`, `GITHUB_TOKEN`, `GEMINI_API_KEY`, proxy vars, …) but never
baked into the image. Your global git `user.name` and `user.email` are passed
through so agent-authored commits are attributed correctly.

## Isolation

Containers run unprivileged: `--cap-drop=ALL`, `--security-opt
no-new-privileges`, a read-only root filesystem, a 2048 pid limit and a memory
cap. Writable paths are `/workspace`, the `/home/dev` volume and a tmpfs `/tmp`.

Nothing from your host home is mounted, so an agent running with
`--dangerously-skip-permissions` (or Codex/opencode equivalents) cannot reach
`~/.ssh`, cloud credentials, or repositories outside `workspace/`.

Because the agents run with their own permission checks disabled, the container
boundary is doing all of the work. Things this does **not** protect against:

- **Network egress is unrestricted** by default; agents can reach any host.
  Use `SANDBOX_NET=none` for untrusted code, or attach a filtered network.
- **Everything in `workspace/` is writable** by an agent with no confirmation
  step, including `git push` if a token is forwarded. Mount only what the agent
  should be allowed to change.
- **`import-creds` copies real logins into the sandbox.** After running it, code
  executing in the container can use those credentials to act as you. Prefer
  logging in inside the sandbox with accounts scoped to what it should reach.

The kernel boundary is a container, not a VM. On macOS there is an extra VM
layer; on Linux there is not.

## macOS notes

Podman runs containers in a Linux VM. Rootless is a property of that VM:

```sh
podman machine inspect podman-machine-default --format '{{.Rootful}}'   # want: false
podman info --format '{{.Host.Security.Rootless}}'                      # want: true
```

Switch a rootful machine:

```sh
podman machine stop && podman machine set --rootful=false && podman machine start
```

Rootless containers cannot bind host ports below 1024 — use `8080`, not `80`.

The macOS Podman package installs the CLI at `/opt/podman/bin`, which is not on
the default `PATH`; `sandbox` adds it automatically.
