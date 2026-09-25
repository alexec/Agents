# Contract: What the app runs over SSH

Every invocation uses `/usr/bin/ssh` (or the test fixture) with the person's `sshName` as the
destination, preceded by `--` handling so the name can never be an option. All run from the app
process, never from `agentsd`.

Common options, called **B** below: `-o BatchMode=yes -o ConnectTimeout=10`.
Over the master, called **M** below: `-S <root>/hosts/<id>.ctl` plus **B**.

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
              "$HOME/.agents-server/bin/current/agentsd" --version 2>/dev/null || echo none;
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
