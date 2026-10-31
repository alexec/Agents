---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Have an agent wait for a branch to move, another agent to finish or the Mac to wake, and carry on by itself when it happens.
---

# Have an agent wait for something

An agent can wait for something to happen, such as a branch moving, another agent
finishing, or the Mac waking. It ends its turn while it waits, which costs nothing, and it
is started again when the thing happens. This guide has an agent wait for `main` to move
and then carry on.

## Before you start

- An agent on any runtime. Every runtime gets the app's `wait_for_event` tool; see
  [Runtimes](../reference/runtimes.md).
- The names of everything an agent can wait for are on [Events](../reference/events.md).

## Steps

1. Tell the agent, in words, what to wait for and what to do afterwards. For example:

   ```text
   Wait for PR 640 to merge, then pull main and run the tests.
   If it has not merged by 6 pm, tell me.
   ```

   You do not need to know the event's name. The agent finds it, here
   `pr.merged` from the `github` server with `pr: 640`, and sets a time limit: yours if you gave one,
   otherwise its own. Every wait has one, from 1 minute to 24 hours, so none can last
   for ever; when it runs out the agent is started again and can wait again.

   Only two of the app's own events can be narrowed: `branch.moved` by `branch`, and
   `person.away` and `person.back` by `why` (`locked` or `idle`). Either can name more than
   one value, meaning any of them, such as `{"branch": ["agents/fix-640", "agents/fix-641"]}`.
   `branch.moved` is only raised for a branch an agent works on, never the folder's default
   branch (#702): this Mac's `main` moves only when someone pulls, so a merge on GitHub would
   never wake it, and a wait on it is refused. Anything else, such as
   `agent.finished` with `{"labels": "deploy"}`, is refused saying what the event takes, so
   the agent fixes it rather than waiting for something that never comes. To wait for
   particular agents to finish, the agent calls `wait_for_agents`.

   An agent can also wait on a connector's event, such as `pr.merged` or `pr.closed`
   from a `github` server. Then `where` is what the server is asked for, such as `{"pr": 640}`
   (the `github` server fills in `repo` from the folder), and the wait subscribes to
   the server until it ends. A name
   no server here offers, or a filter the server doesn't take, is refused with what the
   server does take. See [Events from MCP servers](../reference/events.md#events-from-mcp-servers).

2. If the runtime asks permission to use `wait_for_event`, allow it. Claude and Cursor may
   ask, and Copilot always does.

3. Check that it is waiting. At the end of the chat, a card says, for example,
   **◷ Waiting for pr.merged on github (pr 640) · since 14:02 · until 18:00**. It is under any
   question the agent is waiting on you for, and goes when the wait ends. On the
   folder page, the agent is under **Waiting** with the same line under its report.

4. Leave it. When the pull request merges, the agent is started again with a message saying
   what happened and when, and it carries on with the tests. If the time limit passes
   first, it is started again and told that the wait timed out.

## Stop a wait

- **In the chat, anywhere**: choose **Stop Waiting** on the wait card. On the Mac and the
  web page, **Show in Events** opens the Events page at **Waiting now**, where ✕ on the
  agent's line does the same.
- **Send the agent a prompt.** The agent is told its wait was cancelled by your message, and
  can wait again if it still needs to.

Stopping or archiving the agent also ends its wait.

## Things to know

- **One wait at a time.** An agent that starts a new wait replaces its earlier one.
- **Any one of several.** An agent can wait for several events at once; the first to
  happen wakes it. It can also wait for a whole subject, such as `agent.*`.
- **Nothing is missed.** If more matching events happen before the agent is running again,
  it is told how many, and they are in this folder's events.
- **Across a restart.** A wait survives Agents stopping, crashing or being updated. When it
  next wakes, the agent is told how long Agents was down and which of the events it waits on
  may have been missed in that time, so it can catch up. See
  [Restarts](../reference/events.md#restarts).
- **Its own folder and this Mac.** An agent can wait for its folder's events and the
  Mac's, not another folder's.
- **Time limits** run from 1 minute to 24 hours.

## Have one agent wait for another

Agents do not announce events of their own. To have one agent go on when another is done,
tell it to wait for that agent:

```text
Wait for the agent titled "Build" to finish, then deploy the docs.
```

It calls `wait_for_agents`, and is started again with how the other agent
ended. A workflow can start when an agent finishes too, on `agent.finished`: see
[Workflow triggers and actions](../reference/workflows.md).

## See also

- [Events](../reference/events.md), for every name and its details
- [Statuses and groups](../reference/statuses.md), for **Waiting**
- [Set up a workflow](set-up-a-workflow.md), to start a new agent when something happens
