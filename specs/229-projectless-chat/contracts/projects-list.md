# Contract: the chat project on the wire (#229)

## `projects/list` response: `ProjectSummary`

One new optional key:

```json
{
  "project": { "folder": "file:///Users/alex/.agents/chat", "addedAt": "…", "laidOutAt": "…", "layoutVersion": 2 },
  "name": "chat",
  "exists": true,
  "lastActivityAt": "…",
  "counts": {},
  "isChat": true
}
```

- `isChat` is present and `true` on at most one summary per host, and absent everywhere else.
- Older readers ignore it. `ProjectSummary.init(from:)` already tolerates unknown keys, and the web reads by name.
- `name` is the folder's last component, disambiguated as today. On a server, clients show it as `host:chat`, as they do for any server project.

## `projects/chatState` (new): why there is no chat project

`projects/list` returns a bare array of summaries, so it can't carry a host-level field without breaking older clients. A client asks this only when New Chat is chosen and no listed summary has `isChat` (FR-011). Request `{}`; the response is one of:

```json
{ "ready": { "folder": "file:///Users/alex/.agents/chat" } }
{ "archived": { "folder": "file:///Users/alex/.agents/chat" } }
{ "noPersonalHome": {} }
{ "failed": { "message": "~/.agents/chat is a file, so there is no chat project" } }
```

- It uses the same enum shape as `ChangesUnavailable`, so `scripts/web.sh types` generates a tagged union.
- An older host answers "unknown method". Clients then say "This host has no chat project" with no reason.
- `archived` is also visible without the call when the client lists archived projects (#343): the summary has `isChat` and `archivedAt`.

## Unchanged commands this feature relies on

- `agents/start` with `cwd` = the chat project's folder. It is an ordinary start, with no new start kind.
- `projects/unarchive` for the archived case.
- `worktrees/list` returns `notARepository` for the chat folder.
- The move into a worktree is refused with "Moving needs a git repository, and chat is not in one."
