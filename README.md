# agent-sandbox

Version 0.2.1. Check an install with `sandbox version`.

QEMU VM sandbox for agentic development on macOS. Claude Code, Codex, opencode,
GitHub Copilot CLI and Antigravity (`agy`) run inside a Debian VM that sees
`workspace/` and nothing else from your Mac.

## Setup

**Platform:** macOS on Apple Silicon only, with [Homebrew](https://brew.sh).
Linux and Intel Macs are not supported: the launcher relies on macOS tools
(`hdiutil`) and an arm64 guest image, and the installer exits on anything else.

### Install

One command:

```sh
curl -fsSL https://raw.githubusercontent.com/RomanL1/agent-sandbox/main/install.sh | bash
```

[`install.sh`](install.sh) clones the repo to `~/.agent-sandbox`, links
`sandbox` into `~/.local/bin` (it tells you if that is not on your `PATH`), and
runs `sandbox init`.

It is idempotent: rerun it any time to update. It fast-forwards the checkout,
skips the VM if it is already provisioned, and finishes an `init` that was cut
short (a VM disk without the `vm/provisioned` marker gets provisioned again).

| Variable | Default | |
|---|---|---|
| `SANDBOX_HOME` | `~/.agent-sandbox` | Where the repo is cloned |
| `SANDBOX_BIN_DIR` | `~/.local/bin` | Where the `sandbox` link goes |
| `SANDBOX_BRANCH` | `main` | Branch to install |
| `SANDBOX_SKIP_INIT` | unset | `1` installs without creating the VM |

### Where files live

| Path | Contents |
|---|---|
| `~/.agent-sandbox/` | The repo checkout |
| `~/.agent-sandbox/vm/` | VM disk, Debian image (~430 MB), ssh key, seed, console log, `config` |
| `~/.agent-sandbox/workspace/` | Shared with the VM at `/workspace` |
| `~/.local/bin/sandbox` | Link to `~/.agent-sandbox/sandbox` |
| Homebrew | `qemu` |

Logins made inside the VM live on the VM disk, not on your Mac.

### Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/RomanL1/agent-sandbox/main/install.sh | bash -s -- --uninstall
```

It asks for confirmation, stops the VM, and deletes the checkout, `vm/` (disk,
Debian image, key, every login in the VM) and the `sandbox` link. If
`workspace/` holds files it asks whether to delete them; answer no and they
move to `~/agent-sandbox-workspace`. QEMU stays, since other tools may use it;
`brew uninstall qemu` removes it. Pass the same `SANDBOX_HOME` /
`SANDBOX_BIN_DIR` you installed with.

### From a clone

Instead of the installer:

```sh
./sandbox init
```

`init` runs once and takes several minutes. It:

1. asks for the VM's CPUs, memory and disk size, and whether to pass your git
   name and email into the VM, and saves the answers to `vm/config` (skipped
   if that file exists; without a terminal the defaults are saved);
2. installs QEMU with Homebrew if `qemu-system-aarch64` is missing;
3. downloads the Debian 13 arm64 cloud image (~430 MB) to `vm/` and checks it
   against Debian's `SHA512SUMS`;
4. creates the VM disk as a copy-on-write overlay of that image, plus an ssh
   key and a cloud-init seed, all in `vm/`;
5. boots the VM and waits for ssh;
6. runs [`provision.sh`](provision.sh) as root: packages, Node, firewall, shell
   wrappers, then the agent CLIs as `dev`.

Then (`sandbox` after the installer, `./sandbox` in a clone):

```sh
sandbox claude            # or: codex / opencode / copilot / agy
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
| `init` | Ask for VM settings, install QEMU, fetch the image, create and provision the VM (once) |
| `provision` | Rerun `provision.sh`, after editing it or if `init` was cut short |
| `start` / `stop` / `status` | VM lifecycle; agent commands start it on demand |
| `claude` / `codex` / `opencode` / `copilot` / `agy` | Run that agent with permissions bypassed, args forwarded |
| `shell` | Login shell as the agent user `dev` |
| `root` | Root shell in the VM |
| `run <cmd...>` | One command as `dev` |
| `import-creds [name...]` | Copy host agent logins into the VM |
| `destroy` | Delete the VM disk, dropping all VM state and logins |
| `info` | Resolved settings |
| `version` | Print the version (also `--version`) |

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

`init` saves CPUs, memory, disk size and git forwarding to `vm/config`, one
`KEY=value` per line. Edit it to change them; `destroy` keeps it, so a rebuild
reuses your answers. Memory and CPUs take effect on the next `start`, disk size
only on the next `init`. Variables set in your shell override the file.

Running an agent (or `shell`, `run`, …) before the VM exists offers to run
`init`; a VM whose `init` was cut short offers `provision`.

| Variable | Default | Notes |
|---|---|---|
| `SANDBOX_WORKSPACE` | running VM's, else `./workspace` | Host dir shared at `/workspace`; fixed at boot |
| `SANDBOX_PROJECT` | autodetect | Subdirectory of the workspace to start in |
| `SANDBOX_NET` | `user` | `none` blocks all egress (ssh still works) |
| `SANDBOX_PORTS` | none | e.g. `"8080:8080 5173:5173"`, on `127.0.0.1`; fixed at boot |
| `SANDBOX_MEMORY` | `4G` | VM RAM; fixed at boot. Saved in `vm/config` |
| `SANDBOX_CPUS` | `4` | Saved in `vm/config` |
| `SANDBOX_DISK_SIZE` | `40G` | Used by `init`. Saved in `vm/config` |
| `SANDBOX_GIT` | `1` | `0` keeps your git name and email out of the VM. Saved in `vm/config` |
| `SANDBOX_SSH_PORT` | `2222` | Host port for the VM's ssh |
| `SANDBOX_VM_DIR` | `./vm` | Disk, seed, key, logs |
| `SANDBOX_BASE_IMAGE` | `./vm/debian-13-arm64.qcow2` | |
| `SANDBOX_HOST_HOME` | `$HOME` | Source home for `import-creds` |
| `SANDBOX_NO_BYPASS` | unset | Set to `1` to keep agent permission prompts |

API keys present in the calling shell are forwarded (`ANTHROPIC_API_KEY`,
`OPENAI_API_KEY`, `GITHUB_TOKEN`, `GEMINI_API_KEY`, proxy vars, …) as ssh
environment, so they never show up on a command line. Your global git
`user.name` and `user.email` are passed through so agent-authored commits are
attributed correctly, unless you said no at `init` (`SANDBOX_GIT=0`).

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
