---
name: test-servers
description: Test agents on servers (037 cloud agents) end to end — a real Linux box over real ssh (the agents-devbox Docker container on 127.0.0.1:2222), or the fake ssh for failure cases — by driving a scratch copy of the app through Add a server, a server project, a turn, offline and update. Use whenever a change touches Hosts/, ServerConnection, ServerInstaller, the Linux agentsd, files/browse or files/write, the offline strip, Settings ▸ Servers, or anything that says "server" or "host", or when asked to walk, test or prove servers or cloud agents.
---

# Test agents on servers

A server is reached with the person's own `/usr/bin/ssh`: one master per server, the server's
`daemon.sock` forwarded to `<root>/hosts/<id>.sock`, and a static Linux `agentsd` that the app
installs into `~/.agents-server` over that connection. Two ways to be the server:

| | **devbox** (real) | **fake ssh** |
|---|---|---|
| What it is | Debian container, real sshd, real Linux agentsd | `Fixtures/ssh/ssh`: a folder on this Mac running this Mac's agentsd |
| Proves | the Linux binary, install, forward, a real turn on Linux | every ssh failure sheet, update, reconnect; no network, no Docker |
| Costs | Colima running; a Claude sign-in inside the box for turns | nothing |

Start with the devbox for anything that has to be true on Linux. Use the fake for the failure
states (`FAKE_SSH_FAIL`), which a real sshd will not produce on demand.

This skill sits on top of **run-app**: read that one first. Its rules still hold: a root of your
own, `env -i`, launched behind, never a pattern kill, and always stop what you started.

```sh
S=.claude/skills/run-app/scripts
T=.claude/skills/test-servers/scripts
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

## 2. The window, against the box

```sh
eval "$($S/launch.sh --slug srv)"      # real ssh: nothing extra to set
```

Add the server, all through AX, with no focus taken:

```sh
swift $T/menu.swift $APP_PID "New project" "Add a server…"
swift $T/field.swift $APP_PID "" "agents@127.0.0.1:2222" --confirm      # = Connect
$S/shot.sh $ROOT /tmp/srv-1.png                                          # state B: fingerprint
ssh-keygen -lf ~/.cache/agents-devbox/hostkeys/ssh_host_ed25519_key.pub  # must match the sheet
swift $S/ui.swift press $APP_PID "Trust and continue"
```

Trust installs and starts the server daemon, then lists its runtimes. `$ROOT/hosts/hosts.log`
has every state it went through; `connected` is the one you want. Once the key is trusted in
`~/.ssh/known_hosts`, a new root goes straight past state B.

A project on it:

```sh
swift $T/menu.swift $APP_PID "New project" "127.0.0.1" "Choose Folder…"
swift $T/field.swift $APP_PID "/home/agents" "/home/agents/src/hello" --confirm
swift $S/ui.swift press $APP_PID "Add as project"
```

The project is in the *server's* `projects.json`, not the Mac's:
`$T/devbox.sh ssh cat .agents-server/root/projects.json`.

A turn. **The prompt box can't be typed into over AX**: setting its value changes what's on
screen, not the SwiftUI binding behind it, so Send stays disabled (`button.swift` says so). Send
the turn over the window's own forward instead. It is the same `agents/start` the window's Send
makes, and the window shows the agent live:

```sh
$T/server-rpc.sh $ROOT start claude file:///home/agents/src/hello "Read README.md and say what it is, then run uname -a." 120
$T/server-rpc.sh $ROOT call agents/transcript '{"agentID":"…"}'
$T/server-rpc.sh $ROOT call daemon/status
```

**Never `ui.swift press … "Send"`.** It takes the first pressable match, which is the Services
menu's "Send to Claude". That fires with no input and leaves a modal "There was a problem with
the input to the Service" alert in the window, and every menu is dead until it's dismissed
(`swift $T/button.swift $APP_PID OK`). An unexplained small window in `ui.swift windows` is
usually that alert: `screencapture -x -o -l <id>` shows it.

An immediate `stopped` with `processDied` whose server log says `Authentication required` means
Claude isn't signed in on the box (see §1). The window only says "Claude stopped answering".

To see the typed path through Send, the person must be away. Check idle first
(`ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1e9)}'`, a few minutes at least), then
`launch.sh --front` and real keystrokes.

## 3. The window, against the fake

```sh
F=$PWD/Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/ssh
mkdir -p /tmp/fakehome && : > /tmp/fake-known
eval "$($S/launch.sh --slug fake --env AGENTS_SSH=$F/ssh \
        --env FAKE_SSH_HOME=/tmp/fakehome --env FAKE_SSH_KNOWN_HOSTS=/tmp/fake-known)"
```

Any name works (`fakebox`). The fake "installs" this Mac's own helper agentsd into
`/tmp/fakehome/.agents-server`. Only the environment is read at launch, so each of these needs a
fresh root:

- `--env FAKE_SSH_FAIL=<name>`: every call prints `Fixtures/ssh/stderr/<name>.txt` and exits 255.
  The names are unknownHost, hostKeyChanged, timedOut, refused, loginRefused and
  noStreamLocalForwarding. That covers every failure sheet in `contracts/ui.md`.
- `--env FAKE_SSH_UNAME="Linux x86_64"`: the other architecture.
- `--env FAKE_SSH_LOG=/tmp/fake-ssh.log`: every argv, to check against `contracts/ssh.md`.

## 4. The things worth proving, and how

| What | How |
|---|---|
| Reconnect on relaunch | stop with `--keep`, launch the same root again: `hosts.log` goes to `connected` with no sheet |
| Offline, then back | `devbox.sh down`: heading says Offline · time, strip over a server chat, Send disabled; `devbox.sh up`: back by itself (backs off 1 s → 30 s) |
| Server daemon died | `devbox.sh ssh 'kill $(cat ~/.agents-server/root/daemon.lock)'`: offline, then a new daemon a second later |
| Update | rebuild the app (a new helper checksum), relaunch: install, old daemon asked to quit, new one; `install.json` has the new sha |
| First install | `devbox.sh fresh`, then connect |
| Remove | Settings ▸ Servers ▸ Remove; with purge, `~/.agents-server` is gone on the box, `~/src` is not |
| Files pane | open a server chat's files: it reads through `files/browse`, not this Mac's disk |
| Linux binary itself | `scripts/build-linux-agentsd.sh --check`; copy + `--serve --detach` by hand is in `specs/037-cloud-agents/walk/README.md` |

Record what you saw in `specs/037-cloud-agents/walk/README.md`, with screenshots in `walk/linux/`
(devbox) or `walk/` (fake).

## 5. Clean up

```sh
$S/stop.sh $ROOT
```

`stop.sh` kills the window without `willTerminate`, so **its ssh master survives**. Find it by
its control path and kill that pid only:

```sh
pgrep -f "ssh .*-M -N -S $ROOT/hosts/" | xargs -r kill
```

The server's daemon is meant to outlive the window and keeps running on the box. That is
correct, and `devbox.sh fresh` clears it. Leave the box up unless you started Colima and nobody
else is using it. Remove `$ROOT-srv` (made by `server-rpc.sh`) along with the root.

## Known gaps (as of 2026-09-25)

- Browser pane and workflows list do not work for server projects yet.
- A Mac file attached to a *new* server agent's first prompt isn't carried over.
- The window says "Claude stopped answering" for a runtime that isn't signed in on the server.
- A login refused with an empty ssh agent is classed as a locked key even when the key has no
  passphrase (the devbox's case, if login ever fails).
- A PTY or terminal on a Linux server is unproven.
