# Contract: a server's event as a trigger

This is what a workflow file may say, and what each mistake does. It is the source for the
`on:` docs in `docs/reference/workflows.md`.

Every event is `noun.verbed`, with no prefix, whoever raises it. A server's event is written
exactly like the app's own (`branch.moved`).

## Grammar

```yaml
on:
  - <noun>.<verbed>                    # every server here that offers it
  - <noun>.<verbed>:
      server: <name> | [<name>, …]     # optional: only these servers
      <argument>: <scalar | list | map> # the event's own filters, passed to each server
```

- The name must match `[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*`.
  - If the name is in the app's catalogue, it is the app's event, with today's rules.
  - If its noun is one of the app's subjects (`agent`, `project`, `workflow`, `branch`,
    `lease`, `mac`, `person`, `cost`, `server`) or `custom`, it can only be the app's. An
    unknown name with such a noun is a file error, as today.
  - Any other name is a server's event.
- `server:` is reserved. Its value is the name of an MCP server in the project's
  `.agents/mcp.json`, your `~/.agents/mcp.json`, or a plugin, or a list of them. A list
  means any of them, the same as a list of details on the app's own events.
- Without `server:`, the trigger hears every server here that offers the name, including one
  added later. Each event says which server it came from (`details.server`).
- Arguments: every key but `server`, at most 2 KB as JSON, passed to the server as they are. A
  list is a list argument. It does **not** mean "any of" as it does for the app's own
  details.
- A server's event can be mixed with any other trigger in the same `on:` list.
- `agent: triggering` never runs on it, because no agent is behind it. This is the same as
  for `mac.*` events.

## Example

```markdown
---
name: Fix failed checks
on:
  - checks.failed:
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
| A name not shaped `noun.verbed`, or an unknown name with one of the app's nouns, a bad `server:` value, or arguments over 2 KB | When the file is read | An error in the file, naming the rule | Never |
| No server here offers the name | When subscribing | "No server here offers checks.failed" (`serverNotFound`), and "Did you mean branch.moved?" when a built-in name is close | Never, until one does |
| `server:` names a server that doesn't offer it | After `events/list` | `eventNotOffered` on that server's line, naming the events it does list | Not for that server. The others run. |
| A server's event named against the rules (`branch.created`, `checksFailed`) | After `events/list` | `badEventName`: "ci names an event branch.created, which only the app can raise" | Never |
| An event without `poll` in its `delivery` | After `events/list` | `noPollMode`: "ci offers checks.failed only by push or webhook, which this version doesn't take" | Never |
| Arguments that don't fit one server's `inputSchema` | After `events/list` | `badArguments` on that server's line, shown as an error in the file, naming the keys it takes | Not for that server, until the file or the schema changes. The others run. |

## Matching

- A trigger becomes one subscription per server it hears. It matches an event when the
  event's name equals the trigger's, and the event's `subscription` detail is one of those
  subscriptions' keys ([data model](../data-model.md)).
- Two triggers with an equal event and arguments share the subscription for each server they
  both hear.
- A `wait_for_event` on `checks.failed`, or on `checks.*`, sees events only while some
  workflow on that host subscribes to them. Waits don't create subscriptions in this feature.

For example, with both `github` and `gitlab` set up and offering `pull_request.opened`:

```yaml
on:
  - pull_request.opened            # PRs opened on either; details.server says which
  - pull_request.opened:
      server: github               # GitHub only, filtered by its own argument
      repo: alexec/Agents
  - pull_request.opened:
      server: gitlab
      project: alexec/agents
```
