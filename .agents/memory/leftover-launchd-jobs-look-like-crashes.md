---
name: leftover-launchd-jobs-look-like-crashes
description: "An app that \"keeps crashing\" every ~60s with no crash report is usually a leftover launchctl-submitted helper script, not a fault."
metadata:
  type: feedback
---

When the Agent Loops app or `agentsd` appears to die on a timer, check `launchctl list | grep -i agents`
before reading any code. On 2026-09-19 a job `com.alexecollins.agents-restart` running
`/tmp/agents-restart.sh` quit the app, TERMed the daemon from `daemon.lock` and reopened the app —
once a minute, for hours. `launchctl remove <label>` ended it.

**Why:** `launchctl submit` defaults to KeepAlive, so a one-shot restart script written by an
earlier session is relaunched every time it finishes. The tell is a restart cadence in `daemon.log`
(repeated `listening on …` lines) with **no matching `.ips` in ~/Library/Logs/DiagnosticReports** —
a real fault leaves a crash report, a deliberate quit does not. The script also traps TERM, so
`launchctl remove` takes a few seconds to land.

**How to apply:** never leave a helper script submitted to launchd at the end of a session; run it
in the foreground, or `launchctl remove` it before finishing. Related:
[[agents-app-hosts-this-session]].
