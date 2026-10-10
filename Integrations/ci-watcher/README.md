# CI watcher

A small MCP server that watches this project's GitHub repo and turns its pull requests' CI
into events, tools and a view (#383, [spec](../../specs/383-mcp-integrations/spec.md),
[contract](../../specs/383-mcp-integrations/contracts/ci-watcher-server.md)). It is set up
in the project's `.agents/mcp.json` as `ci`, and the **Fix failed checks** workflow
(`.agents/workflows/fix-failed-checks.md`, off until turned on) runs on its
`checks.failed`.

| Kind | Name | What it does |
| --- | --- | --- |
| Event | `checks.failed` | A pull request's Actions run finished with a failure. Arguments: `repo`, optional `branch` and `pr`. |
| Event | `pr.merged` | A pull request was merged. Arguments: `repo`, optional `branch` and `pr`. |
| Tool | `list_prs` | Open pull requests and their check state. Read-only; feeds the board. |
| Tool | `failed_log` | The last 300 lines of each failed job's log. Read-only. |
| Tool | `rerun_failed` | Reruns a run's failed jobs. |
| Tool | `comment_on_pr` | Comments on a pull request. |
| View | `ui://ci/board` | The open pull requests with a check pill, and **Rerun** on a failing one. |

## What it needs

- **Node 26**, which runs the TypeScript as it is: no dependencies, no build step.
- **A signed-in `gh`** (`gh auth status`). Every GitHub call is `gh api` or `gh pr list` as
  you, so the server holds no token. Without it, tools answer with an error and
  `events/poll` answers `-32012` (`gh not signed in`).

## Running it

The Agents daemon runs it. The project's `.agents/mcp.json` has

```json
{ "mcpServers": { "ci": { "command": "node", "args": ["Integrations/ci-watcher/server.ts"], "hosted": true } } }
```

and `"hosted": true` asks the daemon for one copy per host, shared by every agent's tools
and the workflows that hear its events (#488). It starts on the first call, idles once
nothing uses it, and is started again with backoff if it stops while in use. Its stderr
goes to `mcp-logs/ci-<digest>.log` in the daemon's folder; its state is on the Resources
page. A changed entry is approved again in Project Settings ▸ MCP, as any project server is.

It is a plain stdio MCP server, newline-delimited JSON-RPC on stdin and stdout:

```sh
node Integrations/ci-watcher/server.ts    # in the foreground, speaking on stdin/stdout
```

Before #488 it ran as a LaunchAgent on `127.0.0.1:8795`. One still loaded from then is
taken away with

```sh
launchctl bootout "gui/$(id -u)/com.agents.ci-watcher"; rm -f ~/Library/LaunchAgents/com.agents.ci-watcher.plist
```

## The fake mode

```sh
CI_WATCHER_FAKE=fixtures/ci.json node Integrations/ci-watcher/server.ts
```

With `CI_WATCHER_FAKE` set, nothing calls `gh` or GitHub: pull requests, runs and job logs
are read from the JSON file on every call, and reruns and comments are written back to it
(`reruns`, `comments`). A relative path is tried from the current folder, then from this
one. Append a failed run to `runs` with a fresh `updatedAt`, and the next poll raises it.
Set `"gh": "notSignedIn"`, or `"gh": {"rateLimitedForMs": 60000}`, to see the errors. Copy
the fixture before writing to it; `fixtures/ci.json` is what the tests start from.

## Tests

```sh
node --test Integrations/ci-watcher/
```

They run the server in the fake mode on stdio, against a copy of the fixture.
