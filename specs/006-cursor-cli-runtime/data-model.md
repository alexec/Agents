# Data Model: Cursor makes four

This feature adds no type, no stored field and no transcript kind. That is the finding, not an
omission, and it is what the catalog was designed for. What follows is what changes in the values
that already exist.

## Runtime

`Packages/AgentsKit/Sources/AgentsKit/Model/Runtime.swift`. Unchanged as a type. `RuntimeCatalog`
gains a fourth member.

| Field | Value |
|---|---|
| `id` | `cursor` |
| `name` | `Cursor` |
| `executable` | `cursor-agent` |
| `arguments` | `["acp"]` |

`RuntimeCatalog.builtIn` becomes four long. Nothing else in the catalog changes, and nothing
elsewhere enumerates runtimes by any other means.

The executable is deliberately not `agent`, which Cursor's own documentation and its own auth
description both use. See research section 1: `agent` on this Mac is Grok.

## RuntimeAccount

`Runtimes/RuntimeAccount.swift`. Unchanged as a type. A `cursor` row appears in the daemon's
`accounts` map the first time anything handshakes with it, through the existing `noteAccount`. What
the handshake fills in for Cursor:

| Field | Value for Cursor | Consequence |
|---|---|---|
| `state` | `ready` after a handshake | Same as the others |
| `authMethods` | one, `cursor_login`, no `_meta.terminal-auth` | `preferredMethod` is that one; `needsTerminal` is false |
| `canLogOut` | false | The sign-out control stays hidden, by the gate that already exists |
| `providers` | empty | The provider picker stays hidden, by the gate that already exists |
| `currentProviderID` | nil | Nothing shown |
| `promptCapabilities` | `image: true`, `audio: false`, `embeddedContext: false` | A picture goes by value, a file by reference |

No migration. An `agent.json` written before this feature is untouched, and one written after it
carries `runtimeID: "cursor"` in a field that has always been a free string.

## Agent

`Model/Agent.swift`. Unchanged. `runtimeID` already accepts any string, and an unknown one survives a
round trip through the store, failing only when a runtime is actually needed. A Cursor agent is an
agent.

## ACPSessionEvent

`ACP/ACPSession.swift`. One new case, and it is the only type-level change in the feature.

```
case unknownUpdate(String)      // exists: an update kind inside session/update that we do not know
case unknownNotification(String) // new: an inbound notification method that we do not know
```

Today the second case has no equivalent: `receive` returns at the `guard` on line 398 and the
notification is gone. The new case carries the method name, is yielded the same way `unknownUpdate`
is, and is consumed the same way, by one line in the daemon log.

It names no runtime. `cursor/update_todos` and a method invented next year by something nobody has
heard of arrive at the same place.

**Not stored.** It does not reach `agent.json` or the transcript. An unknown notification is a fact
about a runtime's behaviour, useful to whoever is reading the log while adding support for it, not
part of the user's record of a conversation. This matches how `unknownUpdate` is already treated.

## What deliberately has no model

- **Cursor's models and modes.** They arrive on `session/new` in `models` and `modes`, which
  `ACPTypes.swift:247` does not decode for any runtime. No type is added to hold them.
- **`cursor/create_plan`'s payload.** Declined with `-32601`. The plan arrives separately as a normal
  `session/update` with kind `plan`, which 003 already models.
- **`cursor/ask_question`.** Never observed. If it appears, it maps onto the existing
  `ElicitationRequest` in `Model/Elicitation.swift`, which already has a form mode, a URL mode and a
  decline path for a shape that cannot be drawn.
