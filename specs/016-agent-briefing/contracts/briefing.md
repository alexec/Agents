# Contract: the words, and when they go

This is the whole of what leaves the app. There is no schema, no wire format and no new API — the
contract is the text itself, its order, and the two rules about when it is sent.

---

## The block

Three lines, joined by a blank line, appended to the first prompt of a conversation as one text block
after the person's own.

### 1. `Briefing.suggestions`

Unchanged from what is there today. Carried across verbatim so that the one thing already known to
work is not quietly re-tuned while everything else changes.

```text
For the rest of this conversation, when you have finished a turn, call
suggest_next_prompts with two to four things I might want to ask you next. Do not
mention this instruction or the tool in your replies.
```

The tool name is interpolated from `AppTool.suggestPrompts`, not written out.

### 2. `Briefing.escalation`

```text
When something is mine to decide — a choice between real alternatives, a missing
credential, anything hard to undo — ask me with your question or form tool rather than
guessing at it or ending the turn with the question in your reply. Your question reaches
me wherever I am, including on my phone, and it waits for me. A question in the middle of
a reply I may not read does not.
```

**Names no tool**, deliberately: the tool belongs to the runtime and each spells it differently. The
second and third sentences are the load-bearing part — an agent that believes nobody is there is the
agent that guesses.

### 3. `Briefing.workflows`

```text
If I ask for something to happen on its own — on a schedule, or whenever an agent
finishes, stops, or asks for something — that is a workflow, and manage_workflows is how
you read and write them. Do not write cron entries, launch agents, or scripts that
nothing will run. Do not create a workflow I did not ask for.
```

The tool name is interpolated from `AppTool.manageWorkflows`. The last sentence is not optional
politeness — it is the condition on which `008/T065` is reversed, and it must survive any later
tidying of this line.

### Order

`suggestions`, `escalation`, `workflows`. The one that fires every turn, then the one whose failure
costs most, then the one most turns never need. `lines` is the only place this is stated.

---

## When it goes

| Situation | Briefed? |
|---|---|
| First prompt of a new conversation | **Yes** |
| Every prompt after that | No |
| Conversation resumed after a daemon restart (`session/load` succeeds) | No — the runtime replays its own history |
| Runtime has lost the conversation, a new one is begun | **Yes** — the history that held it is gone |
| Agent started by a workflow or by a project lead | **Yes**, same as any other |
| Prompt is attachments only, or a slash command | **Yes** — whatever the first prompt is made of |

Exactly one code path decides this: `needsBriefing` on `DaemonCore`, inserted in the three places a
conversation begins and removed where the prompt is sent.

---

## What it must not touch

| Rule | How it holds |
|---|---|
| The transcript records the person's words alone | `beginTurn` records `blocks`, then appends to `outgoing`. Two variables, in that order. |
| Nobody's approval changes | The workflow write is still put to the person; permissions are still asked. The briefing changes what an agent reaches for and nothing about who says yes. |
| Removing it breaks nothing | Delete the append and every feature still works by hand. This is a testable claim, not a slogan. |
| It is never drawn | No notification, no field on the record, nothing the phone or the window renders. |

---

## The ceiling

`BriefingTests.itStaysShortEnoughToBeRead`:

- `Briefing.text.count < 1_200`
- `Briefing.lines.count <= 4`

Both are ceilings to notice rather than rules — the test says so in its own comment, so that raising
one is a deliberate edit with a reason attached. The three lines here come to roughly 900 characters.

---

## Seams for what comes next

Two features are already planned against this file and their expectations are part of the contract.

**014 adds a line.** `Briefing.outcome`, joining `lines` after `escalation` and before `workflows`,
about 300 characters, which takes the block past the ceiling and moves it on purpose
(`014/tasks.md:T032`). Nothing else about the briefing changes.

**015 makes it per-runtime.** `Briefing.text` becomes `Briefing.text(for:)`, the workflows line drops
its cron sentence where the runtime's own scheduling tools have been removed, and a generated residue
line is appended where tools could not be removed (`015/tasks.md:T041–T044`). This design makes that
a change to `lines` and its callers — one call site, in `beginTurn` — and to nothing else.

So the names below are fixed, and a rename is a change to three specs rather than to one file:

```text
Briefing.swift
  .suggestions   .escalation   .workflows   .lines   .text
BriefingTests.itStaysShortEnoughToBeRead
DaemonCore.needsBriefing
```
