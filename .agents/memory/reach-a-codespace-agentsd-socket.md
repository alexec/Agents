---
name: reach-a-codespace-agentsd-socket
description: Call a codespace server's agentsd as a client: forward daemon.sock with gh codespace ssh -- -N -L; a shell there is a stranger and strace is blocked
metadata:
  type: reference
---

A Linux server's daemon.sock gives the control role only to sshd's own session process (`roles_linux.go`, `isSSHSession`). A command run there, even with `exec`, is a stranger. To call methods such as `runtimes/signInStart` as a client, forward the socket to the Mac: `env -u GH_TOKEN -u GITHUB_TOKEN /usr/local/bin/gh codespace ssh -c <codespace> -- -N -L /tmp/x/d.sock:/home/codespace/.agents-server/root/daemon.sock`. Then send newline-delimited JSON-RPC to `/tmp/x/d.sock`. `gh codespace cp` failed on `/tmp` paths; send a script with base64 in the ssh command.

The server's log is `~/.local/state/agents/logs/roots/root-*/daemon.log`, which does not record runtime sign-in calls. `ptrace_scope` is 1, so strace cannot attach to agentsd's children: read `/proc/<pid>/io`, or run the tool yourself under `script -qfc` with a FIFO as its stdin. Do not `pkill -f` a pattern that is in your own ssh command line. It kills the ssh. Found for #5202 (2026-11-13). See [[gh-codespace-needs-alex-gh]] in ~/.agents/memory and [[ink-drops-enter-in-a-long-write]].
