# Contract: What the app runs over SSH

Every invocation uses `/usr/bin/ssh` (or the test fixture) with the person's `sshName` as the
destination, preceded by `--` handling so the name can never be an option. All run from the app
process, never from `agentsd`.

Common options, called **B** below: `-o BatchMode=yes -o ConnectTimeout=10`.
Over the master, called **M** below: `-S <root>/hosts/<id>.ctl` plus **B**.

Since #610 every command that logs in also passes **Q**: `-o RemoteCommand=none -o RequestTTY=no
-o ClearAllForwardings=yes`, so nothing in the person's config can break it. A command with no
master of ours also passes **C**: `-o ControlMaster=no -o ControlPath=none`, so it is a
connection of its own. See [Options from the person's config](#options-from-the-persons-config-610).

## 1. Resolve (no network)

```
ssh -G <name>
```
Reads `hostname`, `port`, `user`, `userknownhostsfile`, `hashknownhosts`, `proxyjump`.
Exit ≠ 0 → `unknownHost`.

## 2. Is the key known?

```
ssh-keygen -F <hostname>            # port 22
ssh-keygen -F '[<hostname>]:<port>' # otherwise
    -f <each userknownhostsfile>
```
Found in any → go to 4. Not found → 3.

## 3. Fetch the key without credentials (first connection only)

```
ssh B -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=<tmp>
      -o GlobalKnownHostsFile=/dev/null -o PreferredAuthentications=none
      <name> true
ssh-keygen -lf <tmp> -E sha256
```
The first is expected to fail at authentication; `<tmp>` must be non-empty afterwards, or the
failure is classified from stderr. Sheet state B shows the fingerprint. **Trust and continue**
appends `<tmp>`'s lines to the first `userknownhostsfile` (hashed with `ssh-keygen -H -f` first
when `hashknownhosts yes`). **Cancel** deletes `<tmp>`.

## 4. Master

```
ssh B -M -N -S <ctl>
      -o ControlPersist=no -o ServerAliveInterval=15 -o ServerAliveCountMax=3
      -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes
      [-L <root>/hosts/<id>.sock:<home>/.agents-server/root/daemon.sock]   # only after probe
      <name>
```
Ready when `ssh -S <ctl> -O check <name>` exits 0 (polled every 100 ms, up to 15 s). The first
master for a host is started **without** `-L`, because the home is not known yet. After the
probe it is replaced once with the forward. After that, every master has the forward.

Stopped with `ssh -S <ctl> -O exit <name>`, then SIGTERM if still alive after 2 s.

## 5. Probe

```
ssh M <name> 'uname -sm; printf "%s\n" "$HOME"; df -Pk "$HOME" | tail -1;
              cat "$HOME/.agents-server/install.json" 2>/dev/null | tr -d '\n' || true; echo;
              grep -i "^[[:space:]]*AllowStreamLocalForwarding" /etc/ssh/sshd_config 2>/dev/null || echo default'
```
Five lines, parsed into `ServerFacts`. Any other shape → `installFailed` with the output tail.

## 6. Install / update

```
ssh M <name> 'set -e; umask 077; d="$HOME/.agents-server"; mkdir -p "$d/bin" "$d/root";
              f="$d/bin/.agentsd-<v>.part"; cat > "$f";
              echo "<sha256>  $f" | sha256sum -c - >/dev/null;
              chmod 700 "$f"; mv "$f" "$d/bin/agentsd-<v>"'
    < App bundle/Resources/servers/agentsd-linux-<arch>
```
Then the swap, only when allowed (R6):
```
ssh M <name> 'ln -sfn "agentsd-<v>" "$HOME/.agents-server/bin/current"'
```
On a failed **first** install (the probe said `none` and `~/.agents-server` had no `root/`):
`rm -rf "$HOME/.agents-server"`. On a failed update: `rm -f "$HOME/.agents-server/bin/.agentsd-*.part"`.

## 7. Start the daemon

```
ssh M <name> '"$HOME/.agents-server/bin/current/agentsd" --root "$HOME/.agents-server/root" --serve --detach'
```
Exits 0 once the child is spawned. Readiness is the forward answering `daemon/ping`, which is
`DaemonClient.connect`'s existing loop.

## 8. Remove

After `daemon/quit` over the forward and the socket going away:
```
ssh M <name> 'rm -rf "$HOME/.agents-server"'     # only with the checkbox
```
then stop the master (4) and delete the host record.

## Errors

`SSHCommand.classify(status:stderr:)`, matched on OpenSSH 10.3's own strings (fixtures captured
in `Tests/AgentsKitTests/Hosts/Fixtures/stderr/`):

| stderr contains | Problem |
|---|---|
| `Could not resolve hostname` | `unknownHost` |
| `you have requested strict checking`, without `REMOTE HOST IDENTIFICATION HAS CHANGED` (#610) | `hostKeyUnknown` |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | `hostKeyChanged` |
| `Host key verification failed` (after step 3 trusted) | `hostKeyChanged` |
| `Permission denied (publickey` and `ssh-add -l` lists no identities | `keyLocked` |
| `Permission denied` otherwise | `loginRefused` |
| `Connection timed out`, `Operation timed out`, `No route to host`, `Connection refused` | `timedOut(.connect)` |
| forward setup: `administratively prohibited` | `noStreamLocalForwarding` |
| install: `No space left on device` | `diskFull` |
| anything else | `installFailed(last 3 lines)` |

## Environment

`ssh` is started with the app's environment minus `CLAUDE_*` and `AGENTS_*`, plus
`SSH_AUTH_SOCK` as the app sees it. `SSH_ASKPASS` and `DISPLAY` are removed, so nothing can pop
a prompt the app does not know about.

## Adding a server over ssh (#610)

Run by the control plane (`hosts/install`), not the window. Its `-F <file>` comes first when
`AGENTS_SSH_CONFIG` names one (tests only).

1. **The key, against the person's known_hosts.** Without a fingerprint to trust:
   ```
   ssh B [-i <key> -o IdentitiesOnly=yes -o IdentityAgent=none] -o StrictHostKeyChecking=yes
         [-o "UserKnownHostsFile=~/.ssh/known_hosts ~/.ssh/known_hosts2"]   # only when ssh -G says /dev/null (#514)
         Q C <name> '<probe>'
   ```
   It logs in → the key is one the person trusts, nothing is shown, the install goes on.
   `hostKeyUnknown` → step 2. `hostKeyChanged` → refused, with words for it.
2. **Not known: shown.** § 3's fetch into a temporary file, with **Q C**; the answer is
   `{needsTrust: <SHA256 fingerprint>}`.
3. **Trusted.** The second call carries `trust`. The key is fetched again and used only if its
   fingerprint is that one. It goes into the install's own known_hosts, never the person's.
4. **Tunnel.** `tunnel: true`, or, when the request leaves it out, `ssh -G` says `proxyjump` or
   `proxycommand` (not `none`): the host code names `https://127.0.0.1:<port>`, and the
   control plane holds the tunnel below. Only the control plane on the person's Mac can.

`hosts/sshHosts` (#610): the config's concrete `Host` names (`SSHConfigHosts`, following
`Include`), each resolved with `ssh -G` and no network. With `{destination}`, that alone,
as typed. Each says `resolved` (`user@hostname[:port]`), `throughBastion`, `isBastion` (another
entry's way in) and `known` (a host by that name already).

### The tunnel

```
ssh B <-F> <known hosts> -o StrictHostKeyChecking=yes Q
      -M -N -S /tmp/agents-tunnels-<uid>-<pid>/<id8>.ctl -o ControlPersist=no
      -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes <name>
ssh -S <ctl> -O check <name>                                       # every 0.5 s, up to 60 s
ssh -S <ctl> -O forward -R 127.0.0.1:<port>:127.0.0.1:<port> <name>
```

`<known hosts>` is the key trusted at the install, in a file of the tunnel's own, or, when the
person's known_hosts had it, theirs (with #514's override).

`ClearAllForwardings=yes` drops every `LocalForward`, `RemoteForward` and `DynamicForward` the
config names, and it drops a `-R` on the same command line too (OpenSSH clears forwards after
reading the command line). So the master opens none, and the tunnel's one forward is asked of
it with `-O forward`. When the server will not open it (the port is taken, `AllowTcpForwarding
no`), `-O forward` exits non-zero with `forwarding request failed: <reason>`. The master is
ended and the reason is the tunnel's problem: the host row says **ssh tunnel down: <reason>**.

A session that ends is started again after 2 s, doubling to 60 s while it keeps failing, and
back to 2 s once one has lasted a minute. Every session starts again at once when the Mac wakes
(the clock that counts sleep ran well ahead of the one that does not) or the network's
interfaces change. A server installed again over a tunnel replaces its older tunnel record.

A host dialling through the tunnel binds its proof to `https://127.0.0.1:<port>`; a control
plane that holds tunnels accepts that origin besides its own.

## Options from the person's config (#610)

Checked on 2026-10-10 with OpenSSH 10.3p1 on this Mac against the devbox (sshd on Debian),
each with the arguments above (**B**, **Q**, **C**, `StrictHostKeyChecking=yes`), from a config
written for the check: `specs/037-cloud-agents/walk/ssh-options.sh` runs them all again. Unit tests:
`SSHCommandTests`, `HostTunnelsTests`, `HostInstallTests`; live: `SSHPathLiveTests`
(`AGENTS_SSH_LIVE=1`) and `Walk610LiveTests`.

| Option | What we do | Result |
|---|---|---|
| `HostName`, `User`, `Port` | the config's, through the alias | works |
| `IdentityFile`, `IdentitiesOnly` | the config's; a key chosen in the sheet is `-i` with `IdentitiesOnly=yes` and `IdentityAgent=none` | works |
| `IdentityAgent`, ssh-agent | the config's; `SSH_AUTH_SOCK` is kept (removed only when a key is chosen) | works with the agent alone. 1Password and Secretive are agents on a socket the same way; not tried with those apps |
| `ProxyJump`, chains | the config's; a hop is its own ssh, which reads only the config, so our `-o`s do not reach it | works through one and two hops; a hop's own host key is checked as the config says |
| `ProxyCommand` | the config's | works (`ssh -W %h:%p …`) |
| `Include` | followed by ssh, and by `SSHConfigHosts` for the server box (globs, `~`, relative to `~/.ssh`) | works |
| `Match` | ssh's own reading (`ssh -G`) | `Match host`, `Match exec` work |
| `CertificateFile` | the config's, passed through | `ssh -G` reads it; not tried against an sshd with `TrustedUserCAKeys` |
| `UserKnownHostsFile` | the config's; `/dev/null` alone is replaced by ssh's default files (#514); a key trusted in the sheet goes in a file of the install's own | works; `/dev/null` as given is refused under strict checking, ours logs in |
| `StrictHostKeyChecking` | always `yes` on the command line, which wins over the config's `yes`, `accept-new` or `no` | an unknown key is refused and shown in the sheet, and nothing is written to known_hosts |
| `HashKnownHosts` | read by `HostKeyCheck`; hashed lines match as ssh matches them | works against a hashed known_hosts |
| `ControlMaster`, `ControlPath`, `ControlPersist` | `ControlMaster=no`, `ControlPath=none` on every command with no master of ours; the tunnel's master has its own `-S` and `ControlPersist=no` | works; with `ControlMaster auto` and `ControlPersist 600` in the config, no socket is made at their path |
| `ServerAliveInterval`, `ConnectTimeout` | ours (`ConnectTimeout=10`, and 15 s × 3 on the tunnel) come first and win | works |
| `LocalForward`, `RemoteForward`, `DynamicForward` | cleared on every connection (`ClearAllForwardings=yes`) | with a `RemoteForward` that cannot open and `ExitOnForwardFailure yes`, ours logs in and the tunnel opens; without our options ssh fails with `remote port forwarding failed` |
| `SetEnv`, `SendEnv` | the config's; this app's `AGENTS_*` and `CLAUDE*` are not in ssh's environment | works |
| `RequestTTY` | `no` | with `RequestTTY force`, what we read has no `\r` |
| `RemoteCommand` | `none` | with one in the config, our command runs; without our options ssh refuses (`Cannot execute command-line and remote command`) |
| `user@host:port`, `ssh://user@host:port`, aliases | `user@host:port` is handed to ssh as `ssh://…`; the rest as typed | works |

