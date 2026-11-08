---
name: zsh-log-is-a-builtin
description: In this shell `log show` runs zsh's builtin, prints nothing and looks like "no log lines"; call /usr/bin/log.
metadata:
  type: reference
---

`log` is a zsh builtin (it lists logins), so `log show --predicate …` from the Bash tool
prints nothing at all — which reads exactly like the app never logged. Always
`/usr/bin/log show --last 5m --info --predicate 'processID == <pid> AND category == "…"'`.
`--info` is needed for `Logger.info` lines.

**Why:** cost a round of "is my code even running" on 2026-09-24 proving the terminal
had switched to Metal.

**How to apply:** any time you read unified logs to prove a change in the scratch app
([[drive-a-scratch-window-by-pid-with-ax]]).
