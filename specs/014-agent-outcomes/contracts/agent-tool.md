# Contract: what the agent sees

> **Superseded by 023.** `finish_turn` (`specs/023-end-of-turn-tool/contracts/agent-tool.md`)
> carries this tool's outcome and message together with the next prompts. `report_outcome`
> remains served as an older name with exactly this contract, for conversations briefed
> with it.

The fourth tool on the MCP server the app serves every session, beside
`suggest_next_prompts`, `show_file` and `manage_workflows`. Offered by
`AppService.handle(method:params:)` under `tools/list`; matched on the **end** of the name, because a
runtime may prefix it (`mcp__agents__report_outcome`).

## `report_outcome`

**Title**: Say how the work went

**Description** — the wording matters more than the schema. `AppService.tool` says why: "this
description is the only lever there is", and `Briefing` says the harder truth, that a description
alone got `suggest_next_prompts` called exactly never by three runtimes. So this is written to be
read by an agent that has already been told, in the briefing, to call it.

```text
Call this once, at the very end of your work, after everything else including
suggest_next_prompts. It says how the work actually went, and it is the only thing that
does: without it the app can only say your turn ended, which it will show as an ending
nobody accounted for.

Pick the one that is true:

  done            You did what was asked. Nothing is left for anyone.
  nothing_to_do   You looked, and there was nothing that needed doing.
  needs_answer    You cannot go further until the person answers something.
  partly_done     You did some of it. The rest needs a decision that is not yours.
  stuck           You could not do it, and you know why.

The message is one or two sentences in your own words, and it is what the person reads
on the row before they open anything — so write it for somebody who has not read the
conversation. For needs_answer, the message is the question itself.

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
    }
  },
  "required": ["outcome", "message"]
}
```

**Replies.** A sentence either way, as `AppService.Outcome` requires, so nothing reads as a silent
success.

| Situation | `isError` | Text |
|---|---|---|
| Recorded, no person needed | `false` | `Noted. This conversation now reads as "<heading>" wherever the person looks.` |
| Recorded, a person needed | `false` | `Noted. The person will see this conversation under "Needs attention", with your message on it.` |
| `outcome` missing or not one of the five | `true` | `Nothing was recorded: outcome has to be one of done, nothing_to_do, needs_answer, partly_done or stuck.` |
| `message` empty | `true` | `Nothing was recorded: say in a sentence how it went. An outcome with no words is no more use than the turn simply ending.` |
| Token no longer speaks for an agent | `true` | `That conversation is not open any more, so nothing was recorded.` |
| A permission or form is still outstanding | `true` | `Nothing was recorded: you have a question waiting to be answered, so this work is not over. Answer it first, or let it be answered.` |

## The briefing line

`Briefing.outcome`, joining `lines` after `escalation` and before `workflows` — the file already
anticipates it: "the outcome report of 014 is the next line to join this list". Written as the person
speaking, because it is sent in their turn, and kept short because the whole block is paid for on the
first prompt of every conversation.

```text
Call report_outcome at the end of that same turn, with how it actually went and a
sentence I can read without opening the conversation. Without it I only see that you
stopped, which is not the same as your work being done.
```

**Changed from the draft above during T065**, which re-read the whole block end to end as the file's
own rule demands. The draft opened "When you finish a turn", which `suggestions` has already said —
two lines naming the same moment read as two moments — and listed all five outcomes, which the tool's
schema already enumerates and refuses anything outside. Both are cut. What is left is the one thing
this line has to land: that the call happens at all.

`BriefingTests.itStaysShortEnoughToBeRead` capped the whole block at 1,200 characters. The four lines
come to roughly 1,130, so the ceiling moves to 1,500 — deliberately, in the manner that test already
describes, "a ceiling to notice, not a rule".

## The question a silent agent gets

Sent as an ordinary prompt through `enqueue`, marked `PromptOrigin.app`, once per silent ending.

```text
That turn ended without a report. Call report_outcome now with how it actually went, and
say nothing else. If the work is done, that is done.
```

## What this tool is not

- **Not an interrupt.** It returns at once. Nothing waits on the person (FR-024).
- **Not a replacement for elicitation.** An agent that can carry on after an answer asks with the
  runtime's own question or form tool, which holds the turn open; `Briefing.escalation` already says
  so and is unchanged (FR-025).
- **Not a replacement for `show_file`.** A file still pulls an agent into Needs attention on its own,
  through `AgentsModel.filesToShow`, and neither overwrites the other (FR-026, FR-027).
- **Not drawn as a tool call.** Like `suggest_next_prompts`, the call itself is suppressed in
  `TranscriptEntry.display` — what it did is drawn as the report, and a line saying "called
  report_outcome" would be the same thing said twice.
