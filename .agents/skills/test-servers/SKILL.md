---
name: test-servers
description: Test agents on servers (037 cloud agents, 058 hosts) end to end — a real Linux box (the agents-devbox Docker container on 127.0.0.1:2222) joining a scratch control plane, or the fake ssh for install failures — by driving a scratch set-up through Add a Server, a server project, a turn, offline and remove. Use whenever a change touches Hosts/, ServerInstaller, HostInstall, the Linux agentsd, files/browse or files/write, the offline strip, Settings ▸ Control plane ▸ Hosts, or anything that says "server" or "host", or when asked to walk, test or prove servers or cloud agents.
---

# Test agents on servers

Since 058 a server is a **host**: a static Linux `agentsd` in `~/.agents-server` that dials
out to the control plane over a WebSocket, as this Mac's host does. It joins one of two ways:
- **the shown command** (FR-018): `curl … /v1/install.sh | sh -s -- '<host code>'`, run on
  the server. The control plane serves the script and the Linux host from
  `App/Resources/servers` (`scripts/build-linux-agentsd.sh` builds them);
- **install over ssh** (FR-018a): the control plane runs ssh once with a key it is handed,
  installs, leaves the code, and lets go of the key.

The window never runs ssh: it shows the command or asks the control plane to install.

| | **devbox** (real) | **fake ssh** |
|---|---|---|
| What it is | Debian container, real sshd, real Linux agentsd | `Fixtures/ssh/ssh`: a folder on this Mac running this Mac's agentsd |
| Proves | the Linux binary, install, the join, a real turn on Linux | the install-over-ssh failures (`FAKE_SSH_FAIL`); no network, no Docker |
| Costs | Colima running; a Claude sign-in inside the box for turns | nothing |

Start with the devbox for anything that has to be true on Linux.

This skill sits on top of **run-app**: read that one first. Its rules still hold: a root of your
own, nothing of this session leaked into what you start, launched behind, never a pattern kill,
and always stop what you started.

```sh
S=.claude/skills/run-app/scripts
T=.claude/skills/test-servers/scripts
CONTROL="build/DD-host/Build/Products/Debug/Agents Host.app/Contents/Helpers/agents-control"
```

## 1. The box

```sh
$T/devbox.sh up          # Colima, then the box (built the first time), waits for ssh
$T/devbox.sh status      # sshd, installed agentsd + checksum, running agentsd, Claude sign-in
$T/devbox.sh ssh 'ls ~'  # a command on it; without a command, a shell
```

`agents@127.0.0.1:2222`, key login with `~/.ssh/id_ed25519`, reachable only from this Mac. The
image has Node 22, Claude Code and `claude-agent-acp` on the PATH, plus a repository at
`~/src/hello`. `/home/agents` is the volume `agents-devbox-home`, so sign-ins and repositories
survive `rebuild`. The first box, made before this skill, has no volume: rebuilding it loses its
sign-in.

**A turn needs Claude signed in on the box**, and that is the person's to do: status says
`claude sign-in: NO`. Ask them for `ssh -p 2222 agents@127.0.0.1`, then `claude`, then `/login`, and
carry on with everything that needs no turn while you wait.

The host keys are kept in `~/.cache/agents-devbox/hostkeys` and baked into every image, so a
rebuild is still the same server to `~/.ssh/known_hosts`. The app writes its trusted key there,
the person's own file, on purpose. `devbox.sh ssh` reads `~/.cache/agents-devbox/known_hosts`
instead, so poking at the box by hand never touches theirs.

`devbox.sh fresh` stops the server daemon by its lock pid and removes `~/.agents-server`: the next
connect is a first install. `devbox.sh logs` is the server's `daemon.log`.

### The bare box (043, zero-setup servers)

```sh
$T/bare.sh up            # agents-bare on 127.0.0.1:2223: ssh, curl, xz, git — nothing else
$T/bare.sh status        # node/npx/sign-in (all none), agentsd, Claude toolset
$T/bare.sh rebuild       # a new container: blank disk and a NEW host key — a rebuilt server
```

Join it with the command (§3, `bare.sh ssh` in place of `devbox.sh ssh`), or install over ssh
to `agents@127.0.0.1:2223`. No volume and no fixed host key, on purpose: `rebuild` is a server
rebuilt. `bare.sh ssh` trusts whatever key it
has now and never touches `~/.ssh/known_hosts`.

What the app installs there is **Claude's toolset**: Node and claude-agent-acp, pinned in
`App/Resources/toolsets/claude/` (`scripts/update-claude-toolset.sh` makes a new pin), into
`~/.agents-server/tools/claude/<id>/`, ~484 MB, ~15 s on this Mac's network. It installs as the
server joins whenever Claude on this Mac is signed in with a Claude account (056): a server's
Claude signs in through this Mac's host, relayed through the control plane (T091), and there is
no token to paste. To show "this Mac isn't signed in" without signing anyone out, launch with
`--env AGENTS_TEST_CLAUDE_KEYCHAIN_SERVICE=agents-walk-no-such-item` (it reaches this Mac's host).

After a walk, the Mac's token must be nowhere: pipe it (read with `security find-generic-password
-s 'Claude Code-credentials' -w` and `claudeAiOauth.accessToken`, never echoed) into
`scripts/leak-check.sh $ROOT ssh://agents@127.0.0.1:2223`, which must say `clean`; then the same for
`refreshToken`.

## 2. A scratch control plane the box can reach

```sh
scripts/build-linux-agentsd.sh          # the Linux hosts, into App/Resources/servers (once per change)
eval "$($S/launch.sh --slug srv --lan)" # the control plane at this Mac's LAN address
```

`--lan` is needed because the container cannot reach this Mac's loopback. `launch.sh` points
the control plane at `App/Resources/servers` by itself.

## 3. The box joins

The command, as Add a Server shows it (frame M), and run on the box:

```sh
LINE="$("$CONTROL" code --host --command --home $ROOT/control | sed -n 's/^command\t//p')"
$T/devbox.sh ssh "$LINE"                 # "… joined the control plane."
"$CONTROL" hosts --home $ROOT/control     # the box is listed, as Linux arm64
```

The devbox has no systemd, so the script starts the host detached; `devbox.sh status` shows it.
The window lists the box under its own heading. `devbox.sh logs` has the server's side (an
`uplink:` line says it joined); `$ROOT/control/control.log` has the control plane's.

Install over ssh instead (FR-018a), from the window's Add a Server ▸ Install over ssh, or over
the control plane's socket: the first `hosts/install` answers `needsTrust` with the box's host
key fingerprint, and the second, with the fingerprint, installs. Check afterwards that no ssh
process is left on this Mac and that the key is in no file under `$ROOT/control`.

A project and a turn. The prompt box can't be typed into over AX (setting its value does not
reach the SwiftUI binding), so send the turn to the server's daemon directly. It is the same
`agents/start` the window's Send makes, and the window shows the agent live:

```sh
$T/server-rpc.sh $ROOT call projects/add '{"folder":"file:///home/agents/src/hello"}'
$T/server-rpc.sh $ROOT start claude file:///home/agents/src/hello "Read README.md and say what it is, then run uname -a." 120
$T/server-rpc.sh $ROOT call agents/transcript '{"agentID":"…"}'
```

`server-rpc.sh` forwards the box's `daemon.sock` to `$ROOT-srv/daemon.sock` over its own ssh
(`BOX=bare` for the bare box) and leaves the forward up; `server-rpc.sh $ROOT --stop` ends it.

**Never `ui.swift press … "Send"`.** It takes the first pressable match, which is the Services
menu's "Send to Claude". That fires with no input and leaves a modal "There was a problem with
the input to the Service" alert in the window (`swift $T/button.swift $APP_PID OK` dismisses it).

An immediate `stopped` with `processDied` whose server log says `Authentication required` means
Claude isn't signed in on the box (see §1), or the sign-in this Mac lends through the control
plane (056, T091) did not reach it.

## 4. The fake ssh, for install failures

```sh
F=$PWD/Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/ssh
mkdir -p /tmp/fakehome && : > /tmp/fake-known
eval "$($S/launch.sh --slug fake --control-env AGENTS_SSH=$F/ssh \
        --control-env FAKE_SSH_HOME=/tmp/fakehome --control-env FAKE_SSH_KNOWN_HOSTS=/tmp/fake-known)"
```

The control plane runs the ssh for an install, so the fake goes to it (`--control-env`), not the
host. Only the environment is read at launch, so each of these needs a fresh root:

- `--control-env FAKE_SSH_FAIL=<name>`: every call prints `Fixtures/ssh/stderr/<name>.txt` and
  exits 255. The names are unknownHost, hostKeyChanged, timedOut, refused, loginRefused and
  noStreamLocalForwarding.
- `--control-env FAKE_SSH_UNAME="Linux x86_64"`: the other architecture.
- `--control-env FAKE_SSH_LOG=/tmp/fake-ssh.log`: every argv.

## 5. The things worth proving, and how

| What | How |
|---|---|
| Offline, then back | `devbox.sh down` (or `docker network disconnect`): the host goes offline in the window after about 60 s (two missed pongs); back up, it redials by itself within seconds, with the same daemon |
| Server daemon died | `devbox.sh ssh 'kill $(cat ~/.agents-server/root/daemon.lock)'`: offline; the host's systemd unit or the next command starts it again |
| Control plane restarted | kill the scratch `agents-control` by its pid file and start it again the same way: the box and the window redial without a new code |
| First install | `devbox.sh fresh`, then the command again with a new code |
| Remove | Settings ▸ Control plane ▸ Hosts ▸ Remove: gone from every client at once, and its daemon still running on the box (FR-020) |
| Files pane | open a server chat's files: it reads through `files/browse` on the host |
| Zero-setup (043, 056) | `bare.sh rebuild`, join it with the command: Claude's toolset installs, a Claude agent answers with the sign-in this Mac lends |
| Linux binary itself | `scripts/build-linux-agentsd.sh --check`; copy + `--serve --detach` by hand is in `specs/037-cloud-agents/walk/README.md` |

Record what you saw in the spec's `walks/` (058) or `walk/` (037), with screenshots beside it.

## 6. Clean up

```sh
$T/server-rpc.sh $ROOT --stop
$S/stop.sh $ROOT
```

The server's daemon is meant to outlive the control plane and keeps running on the box. That is
correct, and `devbox.sh fresh` clears it. Leave the box up unless you started Colima and nobody
else is using it.

## Known gaps (as of 2026-09-30)

- Browser pane and workflows list do not work for server projects yet.
- A Mac file attached to a *new* server agent's first prompt isn't carried over.
- ~~The window says "Claude stopped answering" for a runtime that isn't signed in on the server.~~
  043: a refused sign-in says so; no sign-in at all asks for a token before starting.
- A login refused with an empty ssh agent is classed as a locked key even when the key has no
  passphrase (the devbox's case, if login ever fails).
