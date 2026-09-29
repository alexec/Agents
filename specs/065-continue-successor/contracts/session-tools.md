# Contract: list and read sessions in this project

These are tools served by the app to every agent, including a helper another agent started.
They are read-only. The caller's project comes from the caller's agent record; neither tool
accepts a project or folder argument.

## `list_sessions`

Input: no arguments.

The result is a list of live sessions in the caller's project, including the caller and
archived sessions. Retired sessions are not listed. Each item contains:

| Field | Meaning |
|---|---|
| `id` | Stable session UUID, accepted by `read_session`. |
| `title` | Exact title, or `null` when untitled. |
| `runtime` | Runtime display name. |
| `status` | The status shown in the app's agent list, in words. |
| `lastActivityAt` | Time of the last recorded activity, for distinguishing sessions. |
| `lastSaid` | The latest recorded agent report, when present; omitted otherwise. |

The list is ordered by `lastActivityAt` descending, with session UUID ascending as the tie
breaker. An empty project returns an empty list. Listing does not open transcripts or change
any session field.

## `read_session`

Input: `{ "session": string }`.

The value is trimmed. An empty value is refused. Exact title matching is case-sensitive. The
app resolves it in this order:

1. A UUID matching a live session in this project, including the caller or an archived
   session.
2. A UUID matching a retired session in this project: refuse as gone.
3. An exact title matching one live session in this project: read it.
4. An exact title matching more than one live session: refuse and list each match's id,
   runtime, status and last activity time.
5. An exact title matching only a retired session in this project: refuse as gone.
6. Otherwise refuse as not found in this project. Do not reveal whether the value exists in
   another project.

The result is Markdown rendered from the app's transcript record. Its header gives the
session title (or `Untitled`), id, runtime, status, working folder, and worktree name and
branch when present. It contains the person's messages, the agent's replies, non-app tool
calls and their file paths when present, plus the last recorded plan. It omits thoughts,
usage, permission traffic, app-served tool calls, and pool bookkeeping. A read never appends
to the transcript, changes `lastActivityAt`, or broadcasts a session change.

The history budget is 80,000 characters. If the complete rendered history exceeds it, retain
the first request and the newest complete turns that fit, and always retain the last plan.
Include one sentence stating how many turns were omitted. If it fits, return the whole
history without an omission sentence.

## Refusal sentences

- Empty input: `Give a session id or exact title.`
- No live or retired match: `There is no session named “{value}” in this project.`
- Multiple live title matches: `More than one session is named “{value}”: {matches}. Read one by id.`
- Retired id or title: `That conversation is gone.`
- Live session with no readable transcript: `That conversation's history is unavailable.`

Each `{matches}` item is formatted as `{id} — {runtime}, {status}, {lastActivityAt}`. The tool
returns these as a normal readable tool result, not a permission request or a daemon error.
