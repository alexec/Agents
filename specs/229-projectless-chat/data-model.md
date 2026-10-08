# Data model: chat project (#229)

No new stored types. One derived field on the wire, and one derived state per host.

## Chat folder (derived, per host)

| | |
|---|---|
| Value | `personalHome/.agents/chat`, standardised with `Project.standardize` |
| Source | `StoreLocations.personalHome`; nil means no chat folder |
| Stored | nowhere: worked out at start and when listing |

## Project record (existing, `projects.json`)

Unchanged. The chat project is an ordinary `Project`:

- `folder` = the chat folder.
- `addedAt` = when the daemon first made it.
- `laidOutAt` and `layoutVersion` as for any layout.
- `archivedAt` = set only by the person.

## ProjectSummary.isChat (new, wire only)

| Field | Type | Rule |
|---|---|---|
| `isChat` | `Bool`, default `false` | True for exactly the one summary whose folder equals this host's chat folder. Encoded only when true, and decoded with `decodeIfPresent`. |

## Chat project state (new, wire only, per host)

Answered by `projects/chatState` (see the contract), so New Chat can say why it is unavailable (FR-011). It is kept in memory from the last start, and never stored.

| State | When |
|---|---|
| `ready` | A live record exists and the folder is a directory |
| `archived` | The record has `archivedAt` set |
| `noPersonalHome` | `personalHome == nil` (scratch roots, tests) |
| `failed(message)` | The path is a file, or making or laying it out threw. The message is the logged sentence. |

## Start-up transitions

```text
personalHome nil                     → noPersonalHome (nothing on disk)
no record, path missing              → mkdir, layOutOnce(chat: true) → ready
no record, directory there           → layOutOnce(chat: true) (adopts a hand-made folder) → ready
no record, path is a file            → failed("~/.agents/chat is a file")
record, archived                     → archived (nothing on disk changes)
record, live, directory there        → ready (nothing changes)
record, live, folder gone            → mkdir only (no layout: the record says it was laid out) → ready
any step throws                      → failed(message), logged; start carries on
```
