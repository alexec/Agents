# CI watcher

A small MCP server that watches this project's GitHub repo and turns its pull requests' CI
into events, tools and a view (#383, [spec](../../specs/383-mcp-integrations/spec.md),
[contract](../../specs/383-mcp-integrations/contracts/ci-watcher-server.md)). It is set up
in the project's `.agents/mcp.json` as `ci`, and the **Fix failed checks** workflow
(`.agents/workflows/fix-failed-checks.md`, off until turned on) runs on its
`checks.failed`.

| Kind | Name | What it does |
| --- | --- | --- |
| Event | `checks.failed` | A pull request's Actions run finished with a failure. Arguments: `repo`, optional `branch`. |
| Event | `pr.merged` | A pull request was merged. Argument: `repo`. |
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

```sh
node Integrations/ci-watcher/server.ts --port 8795    # in the foreground
Integrations/ci-watcher/run.sh start                  # as a LaunchAgent, com.agents.ci-watcher
Integrations/ci-watcher/run.sh status
Integrations/ci-watcher/run.sh stop                   # unloads and deletes the LaunchAgent
Integrations/ci-watcher/run.sh plist                  # prints the LaunchAgent, changes nothing
```

The LaunchAgent runs `server.ts` from the folder `run.sh` is in, so start it from the
project's main checkout, not from a worktree that will be removed.

Port 8795 because Agents Host holds 8791 (the control plane) and 8792 (the web page), and
the phone bridge 8790. It listens on `127.0.0.1` only, at `POST /mcp` (JSON-RPC, JSON answers), with
`GET /health`. It refuses any `Origin` other than none or `http://127.0.0.1:*`. `--port 0`
picks a free port and prints it. The LaunchAgent logs to `~/Library/Logs/ci-watcher.log`.

## The fake mode

```sh
CI_WATCHER_FAKE=fixtures/ci.json node Integrations/ci-watcher/server.ts --port 8796
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

They run the server in the fake mode on a free port, against a copy of the fixture.
