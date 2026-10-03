---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Check that a runtime works with the app's tools, by having an agent on it work through each one while the app scores what it did.
---

# Assess a runtime

An assessment checks that a runtime, such as Codex after an update, works with the tools the
app gives every agent. An agent on that runtime works through a fixed series of steps, one
for each group of tools: ending a turn, asking you a question, opening a file, starting a
helper, taking a lease, waiting for an event, the Dashboard and workflows. It writes a
report. The app then scores every step from its own record of what the agent called and what
the app answered, so a pass never rests on the agent's word.

## Before you start

- The runtime installed and signed in. See [Sign a runtime in](sign-a-runtime-in.md).
- A project for it to work in. The report goes in that project, in
  `.agents/reviews/runtimes/<runtime>-<date>.md`. Nothing else in it is changed.

## Steps

1. On the Mac, open **Settings ▸ Agent Runtimes** and pick the runtime.
   On an iPhone or iPad, open **Runtimes** at the foot of **Spending**, and touch and hold the
   runtime.
2. Click **Assess…** (on the phone, **Assess in…**) and pick the project.
   The agent starts on the cheapest model the runtime has offered here, such as Haiku for
   Claude, and opens.
3. Answer its two questions: a short form, and one question it asks with the runtime's own
   question tool, where the runtime has one. Any answer will do. If the runtime asks
   permission for a tool, allow it.
4. Leave it. It waits for its helper, then for two one-minute timers, and is started again by
   itself each time. It takes about five minutes.
5. Read the result at the end of the conversation: a table from the app with each step
   passed, failed or not offered, and what the app's record shows. The agent's own report is
   beside it, in the files pane.

If every step passed, the agent parks itself. If not, it waits under **Needs you**, naming
each failure and its likely fix: the app, the runtime's adapter, the runtime's version, or a
setting.

## Things to know

- **Not offered** is not a failure. A runtime with no question tool the app can carry, such
  as Grok or Copilot, is not offered that step.
- **A runtime that can't take an agent** (not installed, not signed in, or out of its
  allowance on the Runtimes page) is not started, and you are told why.
- **The web page** has no Settings or Runtimes page, so it can't start one. It shows an
  assessment's conversation like any other.
- **Archive it** when you have read it. The helper it started is archived by the agent itself.

## See also

- [Runtimes](../reference/runtimes.md)
- [Tools the app gives agents](../reference/agent-tools.md)
