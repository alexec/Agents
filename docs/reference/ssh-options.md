---
diataxis: reference
devices: [mac, server]
description: How each option in your ~/.ssh/config fares when the control plane connects to a server over ssh.
---

# ssh options

When you [add a machine](../how-to/add-a-machine.md) over ssh, the control plane runs the
system `ssh` with your `~/.ssh/config`, through the alias you typed. It adds a few options of
its own on the command line: `StrictHostKeyChecking=yes`, `BatchMode=yes`,
`ClearAllForwardings=yes`, `ControlMaster=no` and `ControlPath=none` (except on the tunnel's
own connection), `RequestTTY=no`, `RemoteCommand=none` and `ConnectTimeout=10`. An option on
the command line wins over the same option in your config.

This table says what happens to each common option in your config. It was checked with
OpenSSH 10.3p1 on a Mac, against an sshd on Debian.

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

## Related

- [Add a machine](../how-to/add-a-machine.md)
- [The control plane](../explanation/control-plane.md)
