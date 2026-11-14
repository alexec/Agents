---
name: launch-the-app-with-a-clean-environment
description: Never `open` Agent Loops.app straight from this session — `open` passes the session's CLAUDE_* env into the daemon and every runtime; use `env -i HOME=… USER=… PATH=… open …`.
metadata:
  type: feedback
---

On 2026-09-23 every resume failed with "Could not resolve authentication method" and
three of Alex's chats were recorded `processDied`. The daemon had been started the night
before with `open` from inside this Claude Code session; `open` passed the session's
`CLAUDECODE`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_MESSAGING_SOCKET`, `CLAUDE_PID` etc.
through to `agentsd`, which handed them to every runtime. While the owning session
process was alive nothing showed; after it died overnight, each runtime's Claude child
treated itself as an orphaned child session and could not authenticate. Reproducing it
from a shell never worked, because the shell's own session was alive.

**Why:** a runtime the daemon starts must be the daemon's, not a child of whatever
session happened to launch the app.

**How to apply:** relaunch with
`env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" SHELL=/bin/zsh TMPDIR="$TMPDIR" PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin LANG=en_US.UTF-8 open <Agent Loops.app>`,
and check `ps eww -p <daemon pid> | tr ' ' '\n' | grep -c ^CLAUDE` is 0. The daemon also
scrubs `CLAUDE*` itself now (`RuntimeEnvironment.forRuntimes`, 2026-09-23), so runtimes are
safe either way; the daemon's own env is still worth keeping clean. Related:
[[agents-app-hosts-this-session]].
