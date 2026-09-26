# Contract: the event tools

These are served by `AppService` on the MCP server every agent already has, and relayed by
`agentsd mcp` to the daemon methods in [daemon-api.md](daemon-api.md). They are offered to
every agent, including one another agent started. Every reply is plain text for the agent to
read. The exact wording lives in `EventWords`, and tests pin the key phrases.

## `wait_for_event`

> Wait until something happens: an event in this project or on this Mac. Your turn can end while
> you wait, and it costs nothing: when the event happens you are started again with it. Also
> lists recent events (`action: recent`) and every event you can wait on (`action: list`). The
> same names work as workflow triggers.

| Input | Type | Notes |
|---|---|---|
| `action` | `"wait"` \| `"recent"` \| `"list"` | Defaults to `wait` |
| `events` | `[string]` | Required for `wait`. For example `pull_request.checks_passed`, `pull_request.*` or `custom.build_green` |
| `where` | `{string: string}` | Optional filters applied to every name, e.g. `{"number": "41"}` or `{"agent": "<id or title>"}` |
| `from` | integer | Optional. Only events after this position count. It comes from `recent` or from an earlier reply. |
| `until_minutes` | integer, 1–1440 | Optional deadline |
| `limit` | integer, 1–50 | Only for `recent`. Defaults to 20. |

An agent title in `where.agent` is resolved to an id, as 039's `waiting_on` is. If the title is
ambiguous or unknown, the call is refused and the reply lists the candidates.

Replies for `action: wait`:

| Case | Reply |
|---|---|
| A match already after `from` | `pull_request.checks_passed happened at 07:41 (position 1042): Checks passed on #41 Fix login redirect. number=41. You can carry on.` |
| A match within 45 s | The same, with "after waiting 12 s" |
| No match within 45 s | `Still waiting for pull_request.checks_passed or pull_request.checks_failed (number 41), since 07:40, until 09:00. Your place is kept; you can end your turn. You'll be started again when one happens.` |
| It replaced an earlier wait | The reply is prefixed with `Replaced your earlier wait on custom.ping.` |
| Refused (-32050) | `"pull_request.merge" is not an event. Did you mean pull_request.merged? Events you can wait on: …` |
| Refused: another project | `You can only wait on this project's events and this Mac's.` |
| Refused: a filter the kind lacks | `pull_request.merged carries number; "branch" is not one of its details.` |

Reply for `action: recent`: newest first, one per line, in the form `1042 · 07:41 ·
pull_request.checks_passed · Checks passed on #41 … · number=41`. It ends with `Head: 1042 —
wait with from: 1042 to catch anything after this.`

Reply for `action: list`: `EventCatalogue.describe()`, which is the same text the
`manage_workflows` description gives.

## The wake prompt (`from: .app`)

This is shown as "Agents asked" in the transcript, never in the person's bubble.

```text
The event you were waiting for happened.

pull_request.merged at 06:55 (position 1031)
#44 Update docs was merged.
number: 44

1 more match arrived before you resumed; wait_for_event with action "recent" to see it.
```

On a timeout: `Your wait for pull_request.merged (number 44) timed out at 09:00 with no match.`

When the person's prompt cancelled the wait, this line is added before their text in the
agent's input, and is not shown in their bubble: `(Your wait for pull_request.merged was
cancelled by this message. Wait again if you still need to.)`

## `cancel_wait`

> Stop waiting. Nothing will start you again for the wait you had.

There is no input.

| Case | Reply |
|---|---|
| A wait was open | `Stopped waiting for pull_request.merged.` |
| None was open (-32051) | `You weren't waiting on anything.` |

## `publish_event`

> Tell other agents and workflows in this project that something happened. The name must start
> with `custom.`. Agents waiting on it are started, and workflows that trigger on it run.

| Input | Type | Notes |
|---|---|---|
| `name` | string | `custom.<name>`, where `<name>` is lowercase letters, digits and `_`, up to 40 characters |
| `message` | string | Optional, up to 500 characters |
| `details` | `{string: string}` | Optional, up to 10 keys of 200 characters each |

| Case | Reply |
|---|---|
| Published | `Published custom.build_green (position 1033). Woke "Merge when green". Fired workflow release-notes.` or `… Nobody was waiting on it and no workflow triggers on it.` |
| Name outside `custom.` (-32050) | `Only custom.* events can be published; mac.wake is raised by the app.` |
| Over the limit (-32050) | `You've published 30 events in the last hour, which is the limit. Try again after 07:58.` |

The consequences in the publish reply are the ones known when the reply is sent. A workflow's
fire may still be starting, and in that case the reply says `Fired` with no agent yet.

## Briefing paragraph

This is one paragraph in `Briefing`. It names `wait_for_event` for "when X happens" instead of
polling, says that the turn can end while waiting, gives `publish_event` for telling others, and
says that `action: list` gives the names.
