# Contract: The tool agents call

A third tool on the MCP server the app already serves every agent, beside `suggest_next_prompts` and `show_file`. It is advertised by `AppService`, carried by the same token-bound helper, and handled in `DaemonCore+AppTools.swift`.

The token is what makes a call belong to an agent — minted per session, bound when the agent exists, dropped when the session ends. That is also what scopes this tool: the calling agent's `cwd` is the project, and there is no parameter for naming a different one.

## `manage_workflows`

```json
{
  "name": "manage_workflows",
  "description": "List, read, create, change and remove this project's agentic workflows. A workflow is a prompt that runs itself when something happens — on a schedule, or when an agent finishes, asks for permission, raises a form, or stops. Creating or changing one asks the person first.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "action": { "enum": ["list", "read", "write", "remove"] },
      "id":     { "type": "string", "description": "The workflow's file name without extension. Required for read, write and remove." },
      "content":{ "type": "string", "description": "The whole file, front matter and body. Required for write." }
    },
    "required": ["action"]
  }
}
```

One tool with an action rather than four tools, matching how the surface reads to a model: an agent that has found this once knows the whole of it.

## What each action does

| Action | Confirmed? | Returns |
|---|---|---|
| `list` | no | Each workflow's id, name, trigger summary, mode, whether it is paused, and its last outcome |
| `read` | no | The whole file, verbatim |
| `write` | **yes** | What was written, and its rendered summary |
| `remove` | **yes** | Confirmation that it is gone |

`list` and `read` raise nothing (FR-034). They are bounded to the calling agent's project, which is the same check `show_file` already makes through `FolderScope`, and reading a file the agent could read with its own file tools anyway is not worth a sheet.

`write` and `remove` block on a confirmation the **daemon** raises, not the runtime (see [research.md §4](../research.md) — the runtimes disagree about whether they ask at all, so waiting for them would be strict under Copilot and wide open under Claude). `autoAllowed(_:)` is narrowed so it never waves this tool through.

## Refusals

Each is a `JSONRPCError` whose message is a sentence, because the agent reads it — the voice `show_file` already uses.

| Condition | What the agent is told |
|---|---|
| Token no longer bound | *"That conversation is not open any more, so nothing was changed."* |
| Path escapes the project's workflow folder | *"Workflows can only be read and written inside this project's `.agents/workflows`."* |
| `write` content has unreadable front matter | *"That front matter could not be read: `<reason>`. Nothing was written."* — validated **before** the confirmation, so nobody is asked to approve a file that would not work |
| No window open | *"No window is open, so there was nobody to ask. Nothing was written."* |
| Declined | *"They declined, so nothing was written."* |
| Two minutes with no answer | *"Nobody answered, so nothing was written. You can ask again."* |
| No such workflow on `read` / `remove` | *"There is no workflow called `<id>` in this project."* |

## Rules

- **Validate before asking.** A `write` whose front matter cannot be parsed is refused outright. Raising a confirmation for a file that could never fire wastes the one moment of the reader's attention this feature gets.
- **No *always allow*.** Every write is confirmed on its own. An agent that could get blanket approval to write workflows could write a workflow that writes workflows.
- **A successful write is live.** No enable step follows (FR-038) — the confirmation *was* the review.
- **The tool is not in the suggestion prompt.** Unlike `suggest_next_prompts`, which needed a sentence in the conversation before any runtime would call it, this one is called because the user asked for a workflow. Adding an instruction telling every agent it can schedule things would be inviting exactly the behaviour the chain-depth limit exists to contain.
