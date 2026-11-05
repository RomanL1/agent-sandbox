# agent-sandbox

QEMU VM sandbox for agentic development on macOS. Claude Code, Codex, opencode,
GitHub Copilot CLI and Antigravity (`agy`) run inside a Debian VM that sees
`workspace/` and nothing else from your Mac.

## Setup

Needs an Apple Silicon Mac with [Homebrew](https://brew.sh). One command does
the rest:

```sh
./sandbox init
```

`init` runs once and takes several minutes. It:

1. installs QEMU with Homebrew if `qemu-system-aarch64` is missing;
2. downloads the Debian 13 arm64 cloud image (~430 MB) to `vm/` and checks it
   against Debian's `SHA512SUMS`;
3. creates the VM disk as a copy-on-write overlay of that image, plus an ssh
   key and a cloud-init seed, all in `vm/`;
4. boots the VM and waits for ssh;
5. runs [`provision.sh`](provision.sh) as root: packages, Node, firewall, shell
   wrappers, then the agent CLIs as `dev`.

Then:

```sh
./sandbox claude          # or: codex / opencode / copilot / agy
```

Log each agent in on its first run, or copy host logins with `import-creds`.

To start over, `./sandbox destroy && ./sandbox init`. The downloaded image is
kept, so a rebuild skips step 2; delete `vm/` to remove everything.

The VM starts on demand and keeps running until `./sandbox stop`. Each agent
logs in inside the VM on first run; logins live on the VM disk.

Agents launch with their permission prompts **bypassed** — the VM is the
security boundary, so approving each edit and command inside it buys nothing.
The same wrappers apply to agents started from `./sandbox shell`. Set
`SANDBOX_NO_BYPASS=1` to restore the prompts, or call `command claude ...`
inside the VM to reach the unwrapped binary.

| Agent | Flag applied |
|---|---|
| `claude` | `--dangerously-skip-permissions` |
| `agy` | `--dangerously-skip-permissions` |
| `codex` | `--dangerously-bypass-approvals-and-sandbox` |
| `copilot` | `--allow-all` |
| `opencode` | `--auto`, on the TUI and `opencode run` — not with a directory argument or other subcommands |

A flag you pass yourself is not duplicated (codex rejects the repeat).

## Running an agent inside one project

Agents start in `/workspace` by default. To start in a project instead:

```sh
cd workspace/myapp && ../../sandbox claude   # cwd inside workspace/ is detected
SANDBOX_PROJECT=myapp ./sandbox claude       # or name it from anywhere
```

The agent can still *see* sibling projects, since the whole `workspace/` is
shared. To hand it one project only, share that directory instead. The share
is fixed when the VM boots, so stop it first:

```sh
./sandbox stop
./sandbox -w ~/code/myapp claude     # or: SANDBOX_WORKSPACE=~/code/myapp
```

While the VM runs, later commands keep using that directory without the
variable, and running from inside it starts the agent in the matching
subdirectory: `cd ~/code/myapp/src && ~/agent-sandbox/sandbox codex`.

## Commands

| Command | Effect |
|---|---|
| `init` | Install QEMU, fetch the image, create and provision the VM (once) |
| `provision` | Rerun `provision.sh`, after editing it or if `init` was cut short |
| `start` / `stop` / `status` | VM lifecycle; agent commands start it on demand |
| `claude` / `codex` / `opencode` / `copilot` / `agy` | Run that agent with permissions bypassed, args forwarded |
| `shell` | Login shell as the agent user `dev` |
| `root` | Root shell in the VM |
| `run <cmd...>` | One command as `dev` |
| `import-creds [name...]` | Copy host agent logins into the VM |
| `destroy` | Delete the VM disk, dropping all VM state and logins |
| `info` | Resolved settings |

## What is in the VM

| | |
|---|---|
| Agents | `claude`, `codex`, `opencode`, `copilot`, `agy` |
| Toolchain | Node 26, Python 3.13, build-essential |
| Dev tools | `git`, `gh`, `ripgrep`, `fd`, `jq`, `curl`, `vim` |

`provision.sh` installs all of it. Agents come from their official installers
into `dev`'s home and update themselves. To change the toolchain, edit
`provision.sh`, then `./sandbox destroy && ./sandbox init`.

The VM is one long-lived system: whatever an agent installs stays for the next
run and for every other agent. `destroy` + `init` is the reset.

### Adding tools

`dev` has no `sudo`. User-level installs persist in its home, and every command
starts through a login shell that sources `~/.sandbox-env`, so a tool only needs
to put itself on `PATH` there:

```bash
./sandbox shell
curl -fsSL https://bun.sh/install | bash
echo 'export PATH="$HOME/.bun/bin:$PATH"' >> ~/.sandbox-env
```

`npm install -g` works as `dev` (prefix `~/.npm-global`). System packages need
`./sandbox root` and `apt`; add them to `provision.sh` to keep them on rebuild.

## Configuration

| Variable | Default | Notes |
|---|---|---|
| `SANDBOX_WORKSPACE` | running VM's, else `./workspace` | Host dir shared at `/workspace`; fixed at boot |
| `SANDBOX_PROJECT` | autodetect | Subdirectory of the workspace to start in |
| `SANDBOX_NET` | `user` | `none` blocks all egress (ssh still works) |
| `SANDBOX_PORTS` | none | e.g. `"8080:8080 5173:5173"`, on `127.0.0.1`; fixed at boot |
| `SANDBOX_MEMORY` | `4G` | VM RAM; fixed at boot |
| `SANDBOX_CPUS` | `4` | |
| `SANDBOX_DISK_SIZE` | `40G` | Set before `init` |
| `SANDBOX_SSH_PORT` | `2222` | Host port for the VM's ssh |
| `SANDBOX_VM_DIR` | `./vm` | Disk, seed, key, logs |
| `SANDBOX_BASE_IMAGE` | `./vm/debian-13-arm64.qcow2` | |
| `SANDBOX_HOST_HOME` | `$HOME` | Source home for `import-creds` |
| `SANDBOX_NO_BYPASS` | unset | Set to `1` to keep agent permission prompts |

API keys present in the calling shell are forwarded (`ANTHROPIC_API_KEY`,
`OPENAI_API_KEY`, `GITHUB_TOKEN`, `GEMINI_API_KEY`, proxy vars, …) as ssh
environment, so they never show up on a command line. Your global git
`user.name` and `user.email` are passed through so agent-authored commits are
attributed correctly.

## Isolation

Agents run as `dev`, an unprivileged user with no `sudo`, inside a VM with its
own kernel. From your Mac the VM sees only `workspace/` (over 9p) and the ports
you forward, bound to `127.0.0.1`. A firewall in the VM blocks your Mac's
`localhost` (QEMU's `10.0.2.2`) and private LAN ranges; the public internet
stays reachable.

`dev`'s uid matches yours, so it can write the workspace and files it creates
there are owned by you.

Things this does **not** protect against:

- **Network egress is unrestricted** to the internet; agents can reach any
  public host. `SANDBOX_NET=none` cuts everything, model APIs included.
- **Everything in `workspace/` is writable** by an agent with no confirmation
  step, including `git push` if a token is forwarded.
- **Files in `workspace/` can run code on your Mac.** An agent can write
  `.git/hooks`, `.git/config` (`core.fsmonitor`), `.envrc`, editor task files
  or `package.json` scripts; running git, direnv, your editor or npm on the Mac
  then executes them outside the VM. Review those before using host tools on
  agent-touched repos, or work from a clone.
- **`import-creds` copies real logins into the VM.** Code running there can
  use them to act as you. Logins macOS keeps in the Keychain (Claude Code, `gh`)
  do not come along; log in inside the VM instead.

## Memory

A freshly booted VM holds about 350 MB. Linux then fills spare guest RAM with
file cache, and QEMU on macOS never hands touched pages back, so the VM grows
towards `SANDBOX_MEMORY` and stays there until it stops. Dropping the guest
cache or a free-page-reporting balloon does not shrink it. Activity Monitor
shows roughly double the real figure (`footprint -p <pid>` gives the real one).

So: size `SANDBOX_MEMORY` to what agents need (4G fits a couple at once) and
`./sandbox stop` when idle, which frees all of it.
