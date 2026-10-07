# Contract: the `mcp.<server>.<event>` trigger

This is what a workflow file may say, and what each mistake does. It is the source for the
`on:` row in `docs/reference/workflows.md`.

## Grammar

```yaml
on:
  - mcp.<server>.<event>                # no arguments
  - mcp.<server>.<event>:
      <argument>: <scalar | list | map>  # the event's own filters, passed to the server
```

- `<server>`: `[A-Za-z0-9_-]+`, the name of an MCP server in the project's `.agents/mcp.json`,
  your `~/.agents/mcp.json`, or a plugin.
- `<event>`: any non-empty text after `mcp.<server>.`, dots included (`checks.failed`).
- Arguments: at most 2 KB as JSON. They are passed to the server as they are. There is no
  `any of` meaning for lists here: a list is a list argument, if the event's schema takes one.
- It can be mixed with any other trigger in the same `on:` list.
- `agent: triggering` never runs on it, because no agent is behind it. This is the same as for
  `mac.*` events.

## Example

```markdown
---
name: Fix failed checks
on:
  - mcp.ci.checks.failed:
      repo: alexec/Agents
agent: new
cooldown: 5m
enabled: false
labels: [ci]
---

A pull request's checks failed. The event's data says which PR, branch and jobs.
Use the `ci` server's `failed_log` to read each failed job. If it is a test known to be
flaky under load, use `rerun_failed`. Otherwise fix it on the PR's branch in a worktree,
push, and use `comment_on_pr` to say what you changed.
```

## What each mistake does

| Mistake | When it is found | What the page shows | Runs |
|---|---|---|---|
| `mcp.` with no server or no event, a server name with a dot or bad character, or arguments over 2 KB | When the file is read | An error in the file, naming the rule | Never |
| A server this project doesn't have | When subscribing | "No MCP server named ci here" (`serverNotFound`) | Never, until it exists |
| A server that offers no events | After the first connection | `noEvents` | Never, until the server's list changes |
| An event the server doesn't list | After `events/list` | `eventNotOffered`, naming the events it does list | Never, until the list changes |
| An event without `poll` in its `delivery` | After `events/list` | `noPollMode`: "ci offers checks.failed only by push or webhook, which this version doesn't take" | Never |
| Arguments that don't fit `inputSchema` | After `events/list` | `badArguments`, shown as an error in the file, naming the keys it takes | Never, until the file or the schema changes |

## Matching

- A trigger matches an event when the event's name is `mcp.<server>.<event>` and its
  `subscription` detail equals the trigger's subscription key ([data model](../data-model.md)).
- Two triggers with equal server, event and arguments share one subscription.
- A `wait_for_event` on an `mcp.` name sees events only while some workflow on that host
  subscribes to them. Waits don't create subscriptions in this feature.
