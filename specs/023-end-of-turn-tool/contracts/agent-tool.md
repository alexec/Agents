# Contract: what the agent sees

`tools/list` from the app's MCP server now returns five entries, in this order:
`finish_turn`, `show_file`, `manage_workflows`, `suggest_next_prompts`, `report_outcome`. The last
two are the aliases. All five are matched on the **end** of the name in `tools/call`, because a
runtime may prefix them (`mcp__agents__finish_turn`).

## `finish_turn`

**Title**: Finish the turn

**Description**

```text
Call this once, as the very last thing you do before you stop. It says how the work
actually went, and it is the only thing that does: without it the app can only say your
turn ended, which it will show as an ending nobody accounted for.

Pick the one that is true:

  done            You did what was asked. Nothing is left for anyone.
  nothing_to_do   You looked, and there was nothing that needed doing.
  needs_answer    You cannot go further until the person answers something.
  partly_done     You did some of it. The rest needs a decision that is not yours.
  stuck           You could not do it, and you know why.

The message is one or two sentences in your own words, and it is what the person reads
on the row before they open anything — so write it for somebody who has not read the
conversation. For needs_answer, the message is the question itself.

With it, offer two to four things the person might want to say next, shown as buttons
above their prompt. Take them from the work you just did: what you did not do, a check
worth running, a decision you had to guess at, the obvious next step. Write each one as
a prompt the person would send you, in the second person ("Run the tests and fix what
fails"). Leave them out only if there is genuinely nothing worth asking next. Say
nothing in your reply about having called this.

If you can carry on once you have an answer, do not use this: ask with your question or
form tool, which stops and waits for them. This one does not wait. It is how you end.
```

**Input schema**

```json
{
  "type": "object",
  "properties": {
    "outcome": {
      "type": "string",
      "enum": ["done", "nothing_to_do", "needs_answer", "partly_done", "stuck"],
      "description": "The one that is true."
    },
    "message": {
      "type": "string",
      "description": "One or two sentences, for somebody who has not read the conversation. For needs_answer, the question itself."
    },
    "next_prompts": {
      "type": "array",
      "minItems": 0,
      "maxItems": 4,
      "description": "Two to four things the person might say next, best first. Leave out if there is nothing worth asking.",
      "items": {
        "type": "object",
        "properties": {
          "label":  { "type": "string", "description": "Two to five words for the button, e.g. \"Run the tests\"." },
          "prompt": { "type": "string", "description": "The prompt itself, addressed to you, which goes into their prompt box when they tap it." }
        },
        "required": ["label", "prompt"]
      }
    }
  },
  "required": ["outcome", "message"]
}
```

**Replies.** A sentence either way. On success the outcome's sentence comes first and the chips'
sentence after it, so an agent that reads only the first line still learns the important half.

| Situation | `isError` | Text |
|---|---|---|
| Recorded, no person needed, chips shown | `false` | `Noted. This conversation now reads as "<heading>" wherever the person looks. <n> shown above the prompt.` |
| Recorded, a person needed, chips shown | `false` | `Noted. The person will see this conversation under "Needs attention", with your message on it. <n> shown above the prompt.` |
| Recorded, no chips | `false` | The first sentence alone. |
| `outcome` missing or not one of the five | `true` | `Nothing was recorded: outcome has to be one of done, nothing_to_do, needs_answer, partly_done or stuck.` |
| `message` empty | `true` | `Nothing was recorded: say in a sentence how it went. An outcome with no words is no more use than the turn simply ending.` |
| Token no longer speaks for an agent | `true` | `That conversation is not open any more, so nothing was recorded.` |
| A permission or form is still outstanding | `true` | `Nothing was recorded: you have a question waiting to be answered, so this work is not over. Answer it first, or let it be answered.` |

A refused call shows nothing: no chips, no report.

## The aliases

Schemas, argument rules and replies are exactly those in 014's `contracts/agent-tool.md` and the
suggestion tool's existing entry. Only the descriptions change, to one paragraph each:

**`suggest_next_prompts`** — *Title*: Suggest what to ask next (older name)

```text
The older name for the suggestions half of finish_turn. Use finish_turn instead: it
takes the same prompts and the outcome together. This still works, and shows the
prompts as buttons above the person's prompt.
```

**`report_outcome`** — *Title*: Say how the work went (older name)

```text
The older name for the outcome half of finish_turn. Use finish_turn instead: it takes
the same outcome and message and your suggestions together. This still works, and
records how the work went.
```

Calling an alias affects only its half: `suggest_next_prompts` replaces the chips and leaves the
report; `report_outcome` replaces the report and leaves the chips. Calling `finish_turn` replaces
both.

## What this tool is not

- **Not an interrupt.** It returns at once; the turn ends afterwards in the ordinary way.
- **Not a replacement for elicitation.** The last paragraph of the description is 014's, verbatim.
- **Not a replacement for `show_file` or `manage_workflows`.** Neither changes.
- **Not drawn as a tool call.** Suppressed in `TranscriptDisplay` like the two it replaces.
