# Contract: Starting Gemini

## On the Mac

```text
npx -y @google/gemini-cli@0.61.0 --acp --policy <root>/runtimes/gemini-policy.toml
```

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
toolName = ["invoke_agent"]
decision = "deny"
priority = 900
denyMessage = "<RemitCategory.agents.instead>"

[[rule]]
toolName = ["tracker_create_task", "tracker_update_task", "tracker_get_task",
            "tracker_list_tasks", "tracker_add_dependency", "tracker_visualize"]
decision = "deny"
priority = 900
denyMessage = "<RemitCategory.standingArrangements.instead>"
```

One rule per category, so each refusal names the app's own tool. Priority is high so a
person's own `allow` rule for the same tool does not win inside the app's agents; it has no
effect outside them. (Exact priority band confirmed in the spike against Gemini's policy docs.)

## On a server

```text
<toolset>/node/bin/node <toolset>/node_modules/@google/gemini-cli/bundle/gemini.js --acp --policy <server root>/runtimes/gemini-policy.toml
```

- Environment: the server's, with `GEMINI_API_KEY` set to the lent key and `GOOGLE_API_KEY`
  removed, for this process only; nothing when the host is "own sign-in only".
- A missing key and no own sign-in: `credentialWanted` (043's -32036) before anything starts.

## Refusals the app reads

| From Gemini | App shows |
|---|---|
| `session/new` error `-32000` | **Needs signing in** + sheet (existing path) |
| process exits before `initialize` answers, stderr names an unknown argument | "Gemini <version> did not start in a mode the app can talk to." |
| npx exits non-zero before starting, stderr from npm | "Could not download Gemini: <npm's reason>." |
| prompt error / refusal carrying `RESOURCE_EXHAUSTED` or 429 | "Gemini's quota ran out: <Gemini's sentence>." (shape settled in the spike) |
