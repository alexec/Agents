---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Have an agent wait for checks to pass, another agent to finish or the Mac to wake, and carry on by itself when it happens.
---

# Have an agent wait for something

An agent can wait for something to happen, such as a pull request's checks passing,
another agent finishing, or the Mac waking. It ends its turn while it waits, which costs
nothing, and it is started again when the thing happens. This guide has an agent wait for
a pull request's checks and then carry on.

## Before you start

- An agent on Claude, Grok or Cursor. Copilot conversations do not get the app's tools,
  so a Copilot agent cannot wait. See [Runtimes](../reference/runtimes.md).
- For waiting on a pull request: a project on GitHub, set up as in
  [Have an agent watch a pull request](watch-a-pull-request.md).
- The names of everything an agent can wait for are on [Events](../reference/events.md).

## Steps

1. Tell the agent, in words, what to wait for and what to do afterwards. For example:

   ```text
   Wait for the checks on pull request 41 to pass, then write the release notes for it.
   If they have not passed by 6 pm, tell me.
   ```

   You do not need to know the event's name. The agent finds it, here
   `pull_request.checks_passed` with `number: 41`, and sets a time limit if you gave one.

2. If the runtime asks permission to use `wait_for_event`, allow it. Claude and Cursor may
   ask.

3. Check that it is waiting. Above the prompt, the chat shows a capsule such as
   **◷ Waiting for pull_request.checks_passed #41 · since 14:02 · until 18:00**. On the
   project page, the agent is under **Blocked** with the same line under its report.

4. Leave it. When the checks pass, the agent is started again with a message saying what
   happened and when, and it carries on with the release notes. If the time limit passes
   first, it is started again and told that the wait timed out.

## Stop a wait

- **On the Mac**: click ✕ on the capsule above the prompt, or on the agent's line under
  **Waiting now** on the Events page.
- **Anywhere, including the phone and iPad**: send the agent a prompt. A line above the
  prompt says **Sending will cancel the wait on …** before you do. The agent is told its
  wait was cancelled by your message, and can wait again if it still needs to.

Stopping or archiving the agent also ends its wait.

## Things to know

- **One wait at a time.** An agent that starts a new wait replaces its earlier one.
- **Any one of several.** An agent can wait for several events at once; the first to
  happen wakes it. It can also wait for a whole subject, such as `pull_request.*`.
- **Nothing is missed.** If more matching events happen before the agent is running again,
  it is told how many, and can look them up.
- **Its own project and this Mac.** An agent can wait for its project's events and the
  Mac's, not another project's.
- **Time limits** run from 1 minute to 24 hours.

## Have agents tell each other

An agent can announce something with its `publish_event` tool, and other agents in the
project can wait for it. For example, tell one agent:

```text
When the build is green, publish custom.build_green.
```

and another:

```text
Wait for custom.build_green, then deploy the docs.
```

The publishing agent is told who it woke. A workflow can start on the same event: see
[Workflow triggers and actions](../reference/workflows.md).

## See also

- [Events](../reference/events.md), for every name and its details
- [Statuses and groups](../reference/statuses.md), for **Blocked**
- [Set up a workflow](set-up-a-workflow.md), to start a new agent when something happens
