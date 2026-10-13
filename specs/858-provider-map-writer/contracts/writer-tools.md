# Contract: the writer's tools

App tools, offered only to an agent started with `purpose: providerDraft` (research R3). The
daemon relays each one to the control plane on channel 0 as `host/providerDraft`
(`{token, draft, tool, arguments}`). Every answer is text, redacted (R4), and cut at 16 KB with
a line that says so (FR-015). Every call is a step.

| Tool | Arguments | For | Answer |
|---|---|---|---|
| `read_tools` | none | MCP | Each tool of the server: its name, description, input schema and annotations. |
| `read_help` | `words: [String]` | CLI | The output of `‹cli› ‹words…› --help`. `words` are plain words (letters, digits, `-`, `_`). Nothing else runs. |
| `check_draft` | `draft: object` | both | "Passed: listed N: …" with each workspace as the map reads it, or "Failed: ‹the check's words›". Or "The person must run this check: ‹reason›", when the safety rules say ask (FR-013, FR-014), and then the answer of the person's Run Check. |
| `prove_start` | `workspace: String` | both | "Started ‹name›: ‹state›" or "Failed: …" or "The person said no." Waits for the person (R6). |
| `prove_stop` | `workspace: String` | both | As `prove_start`. |
| `send_draft` | `draft: object`, `note: String` | both | "Sent." The draft goes to the sheet. The last one sent is the result. The agent should end its turn. |
| `give_up` | `reason: String` | both | "Ended." The sheet shows the reason (spec, edge cases). |

**Rules for every tool**

- Refused, with "This tool is for the agent writing that provider's map.", for any other caller
  (FR-011).
- After 8 `check_draft`, 40 calls in all, or 5 minutes (less asking and proving), each tool
  answers "The time for this draft is over: send your best draft with send_draft, or give_up."
  One more `send_draft` or `give_up` is taken, then the draft ends (FR-017).
- `check_draft` and `send_draft` validate the draft first, as `ToolMapping.map` or the command
  provider's config parser does, and answer their words when it does not parse.
- None of them takes a secret's value, and none answers one.
