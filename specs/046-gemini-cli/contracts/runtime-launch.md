# Contract: Starting Gemini

## On the Mac

```text
<root>/tools/gemini/current/bin/gemini --acp --policy <root>/runtimes/gemini-policy.toml
```

`bin/gemini` is the toolset's shim: `exec <toolset>/node/bin/node <toolset>/lib/node_modules/@google/gemini-cli/bundle/gemini.js "$@"`.
Nothing is looked up on the PATH, so a person's own `gemini` is never used (D1).

- cwd: the agent's folder (or worktree), as for every runtime.
- Environment: the login shell's (`LoginShellPath.environment()`), unchanged. Gemini's own
  sign-in (`~/.gemini/oauth_creds.json`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`) is used as is (D3).
- Nothing lent on the Mac.
- `session/new` / `session/load`: `mcpServers` carries the app's MCP server, as for the
  others. No `_meta` for Gemini (its lever is the file).

## The policy file

Rebuilt before every launch from `ToolPolicyCatalog.gemini.removed`; never read back.

```toml
# Written by the Agents app. Do not edit: rebuilt on every launch.

[[rule]]
toolName = ["tracker_create_task", "tracker_update_task", "tracker_get_task", "tracker_list_tasks", "tracker_add_dependency", "tracker_visualize"]
decision = "deny"
priority = 999
denyMessage = "<RemitCategory.standingArrangements.instead>"

[[rule]]
toolName = ["invoke_agent"]
decision = "deny"
priority = 999
denyMessage = "<RemitCategory.agents.instead>"
```

One rule per category, so each refusal names the app's own tool. Priority 999 is the top of the band Gemini's loader allows (0–999; it adds the file's tier, so
1000 would jump tiers and is refused). Which tier `--policy` files land in, and so whether a
person's own `allow` could still win, is confirmed in the spike.

## On a server

```text
~/.agents-server/tools/gemini/current/bin/gemini --acp --policy <server root>/runtimes/gemini-policy.toml
```

- Environment: the server's, with `GEMINI_API_KEY` set to the lent key and `GOOGLE_API_KEY`
  removed, for this process only; nothing when the host is "own sign-in only".
- A missing key and no own sign-in: `credentialWanted` (043's -32036) before anything starts.

## Refusals the app reads

| From Gemini | App shows |
|---|---|
| `session/new` error `-32000` | **Needs signing in** + sheet (existing path) |
| process exits before `initialize` answers, stderr names an unknown argument | "Gemini <version> did not start in a mode the app can talk to." |
| status `missing` | "Gemini isn't on this Mac." with the row's **Install** |
| status `installing` | "Gemini is being installed." with its step |
| status `installFailed` | 048's sentence, with **Retry** and **Open install page** |
| prompt error / refusal carrying `RESOURCE_EXHAUSTED` or 429 | "Gemini's quota ran out: <Gemini's sentence>." (shape settled in the spike) |
