---
diataxis: how-to
devices: [mac]
description: Check that a runtime works with the app's tools, by having an agent on it work through each one while the app scores what it did.
---

# Assess a runtime

An assessment checks that a runtime, such as Codex after an update, works with the tools the
app gives every agent. An agent on that runtime works through a fixed series of steps, one
for each group of tools: ending a turn, asking you a question, opening a file, starting a
helper, taking a lease, waiting for an event, workflows, moving into a worktree and back,
reading its own session, and writing outside the folder. It writes a report. The app then
scores every step from its own record of what the agent called and what the app answered,
so a pass never rests on the agent's word.

## Before you start

- The runtime installed and signed in. See [Sign a runtime in](sign-a-runtime-in.md).
- A folder for it to work in, ideally a git repository so it can try a worktree. The
  report goes in that folder, in `.agents/reviews/runtimes/<runtime>-<date>.md`. The
  workflow and the worktree it makes there are removed again before it ends.

## Steps

The app has no button for an assessment (#2133). The **Runtime check** workflow assesses a
runtime when a release updates it, and you can start one by hand:

1. In a chat in this folder, ask an agent to assess the runtime, for example "Assess Codex".
   It uses the `assess-runtime` skill. Or, in a terminal in the folder, run
   `.agents/skills/assess-runtime/scripts/assess.py <root> <runtime> --folder <folder>`.
2. The assessing agent starts on the cheapest model the runtime offers, such as Haiku for
   Claude. The script answers its questions and permission cards as a person would: the
   form, the runtime's own question, and an allow for each card, except the write outside
   the folder, which it rejects.
3. Leave it. It waits for its helper, then for two one-minute timers, and moves into a
   worktree and back, and is started again by itself each time. It takes about six minutes.
4. Read the result at the end of the assessing agent's conversation: a table from the app
   with each step passed, failed or not offered, and what the app's record shows. The
   agent's own report is beside it, in the files pane.

If every step passed, the agent asks to be archived. If not, it waits under **Needs you**, naming
each failure and its likely fix: the app, the runtime's adapter, the runtime's version, or a
setting.

## Things to know

- **Not offered** is not a failure. A runtime with no question tool the app can carry, such
  as Grok or Copilot, is not offered that step. Nor is a worktree in a folder that is not a
  git repository, or a permission card where the runtime refuses the write outside the
  folder by itself.
- **The report names** the runtime's adapter and version, as it gave them when it started,
  and where it ran.
- **A runtime that can't take an agent** (not installed, not signed in, or out of its
  allowance on the Runtimes page) is not started, and you are told why.
- **Every client** shows an assessment's conversation like any other: the Mac, the Remote
  and the web page.
- **Archive it** when you have read it. The helper it started is archived by the agent itself.

## See also

- [Runtimes](../reference/runtimes.md)
- [Tools the app gives agents](../reference/agent-tools.md)
