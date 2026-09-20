# Research: What Every Agent Is Told

Five decisions. The first is the only one with a measurement behind it, and it is the one the whole
feature rests on. The others are judgements, recorded with what they were weighed against.

---

## 1. Are words necessary at all, or is a good tool description enough?

**Decision**: words are necessary. A tool this app needs *called* has to be named in the
conversation; a description is not enough at any length.

**Evidence**: `suggest_next_prompts` was served with a long, carefully written description — "This
description is the only lever there is", the comment above it said, and it was rewritten more than
once on that belief. Across the Claude adapter, Copilot and Grok it was called **exactly never**.
One sentence added to the first prompt, and Claude and Grok both came back with four suggestions on
the next turn. `SuggestedPromptLiveTests` exists because of that run, and `014/quickstart.md` repeats
the finding independently: "the briefing is the whole of the lever here".

**Rationale**: a description is read by something already looking for a tool to solve a problem it
has. Ending a turn well, asking rather than guessing, and noticing that "every morning" is a thing
the app owns are not problems a model has — they are problems the *app* has. Nothing sends the model
looking, so nothing reads the menu.

**Alternatives considered**:

- *Better descriptions.* Tried, repeatedly, for one tool. It is the thing that failed.
- *A tool name so obvious it gets picked up.* Does not survive contact: `manage_workflows` is about
  as plain as a name gets, and an agent that does not know standing arrangements exist here has no
  reason to go looking for it.
- *Per-turn nudges.* Works, and costs a multiple of what this costs. See decision 3.

---

## 2. Should the workflow tool be named in the briefing at all?

**Decision**: yes, with the restraint in the same sentence.

**This reverses a written decision.** `008/tasks.md:T065`: *"Do NOT add it to `askForSuggestions` or
any other standing instruction — telling every agent it can schedule things would invite exactly the
behaviour the chain-depth limit exists to contain."* The comment above `AppService.workflowTool` says
the same thing in prose.

**Rationale**: that decision weighed one failure and not the other. The danger it names is real — an
agent that learns it can schedule things starts scheduling them, and a workflow that starts an agent
that writes a workflow is exactly what the chain-depth limit exists to contain. What it did not
weigh is the cost of silence, which is not "no workflow gets created". It is an agent asked for
something recurring writing a cron line into a comment, or a launch agent nobody loaded, or a note
in a README addressed to a human, and then **reporting that it is set up**. The person is told the
thing is handled and it is not. That is worse than either alternative.

Two things make the reversal safe. The restraint travels in the same sentence as the capability — the
line says both *use this when asked* and *do not invent one nobody asked for* — and every guard that
exists today is untouched: a write is still put to the person in plain words, and the chain-depth
limit still holds whatever an agent has been told.

**Alternatives considered**:

- *Leave it out, per T065.* Rejected on the cost above. The failure it prevents is bounded by
  approval and depth limits; the failure it causes is unbounded and silent.
- *Say only the negative* — "do not write cron entries" — without naming the tool. Rejected: an agent
  told only what not to do does the next-worst thing, which is to write a script and say it cannot
  schedule it.
- *Name it only when the person's words look recurring.* Rejected: detecting that is a guess made on
  the first prompt of a conversation, before anything is known, and being wrong is silent.

---

## 3. How often are the words sent?

**Decision**: once, with the first prompt of a conversation. Again only when a runtime has lost the
conversation and a new one is begun in its place.

**Rationale**: this is the existing answer for the existing sentence, and it holds for the same
reason at four times the length. The words stay in the runtime's own history, and that history is
what a runtime replays when a conversation is picked back up, so sending them again is paying twice
for something already said. A conversation the runtime has forgotten is the one case where the
history genuinely no longer holds them.

The economics decide how much can be said at all. Per-turn, every line is charged on every prompt
forever, and the briefing has to stay at one sentence — which is how the current state came to be
the thing being replaced. Once per conversation, four lines are affordable.

**Alternatives considered**:

- *Every turn.* Rejected on cost, and it would make FR-018's room for growth a lie.
- *Once per agent rather than once per conversation.* Wrong unit. An agent outlives its runtime
  conversations; a runtime that has lost one has lost the words with it.
- *On the system prompt or a runtime config file.* Not available. ACP has no such channel, and
  writing into `~/.claude` or `~/.grok` is out of bounds — the same rule 015 holds itself to.

**Known weakness**: a runtime that summarises or truncates its own history may drop the words late
in a long conversation. Recorded in the spec's assumptions; the symptom is an agent that stops
following the briefing after many turns, and the answer if it ever shows up is to re-send on some
signal, not to re-send always.

---

## 4. How is escalation named, when the tool is not ours?

**Decision**: name the act, not the tool. Give the reason the app can vouch for.

**Rationale**: the question channel is reached through the runtime's own tool and each spells it
differently — the Claude adapter raises an elicitation from `AskUserQuestion`, and Copilot ships a
rival `escalation_raise` through an MCP server the person may already be running. Naming any one of
them is wrong on the other three, and naming all four is a paragraph that is mostly wrong for
whoever reads it.

What the app *can* say truthfully to every agent is why it is worth doing: the question is held by
the daemon, it survives the window being shut, and it is drawn on the person's phone. An agent that
believes nobody is there is the agent that guesses, so the reason is the load-bearing half of the
line.

**Alternatives considered**:

- *Name each runtime's tool.* Rejected: it would be the first place in the app that branches on
  runtime identity for a reason other than a capability table.
- *Serve an escalation tool of our own* and name that. A real option, and a bigger feature — it
  would mean the app holding the question rather than the runtime, and it is the natural follow-on
  if the act-only line proves too weak. Out of scope here.
- *Say nothing and rely on the runtime's own instincts.* This is today, and today an agent ends its
  turn with the question in a reply nobody has open.

---

## 5. Where does it live, and what shape?

**Decision**: a `Briefing` enum in `AgentsKit/ACP/Serve/Briefing.swift`, one static string per line,
plus `lines` and `text`. `AppService.askForSuggestions` goes away rather than staying as an alias.

**Rationale**: the module split is on whether the phone needs it — `AppTool` is in `AgentsKitCore`
because a remote reading a transcript must tell the app's tool calls from the agent's work, and the
briefing is never drawn anywhere. The separate file is because `AppService` answers "what may an
agent do" and this answers "what is an agent told", and because both 014 and 015 plan to edit the
second without touching the first.

A list rather than a concatenation is what makes a fourth line a one-line change (FR-018, FR-020) and
what the ceiling test iterates.

**Alternatives considered**:

- *Keep `askForSuggestions` as an alias.* Rejected: two names for one string, and the next reader has
  to work out which is canonical. The only caller outside tests is `beginTurn`.
- *A stored, editable briefing — per project or per agent.* Rejected as a separate feature, recorded
  in the spec's assumptions. It would need a store, a surface to edit it in, and an answer for what
  a workflow-started agent inherits.
- *Markdown or a templated document.* Rejected. Four sentences do not need a format, and a format
  invites length.

---

## Ceiling

**Decision**: the whole block stays under 1,200 characters and four lines, enforced in
`BriefingTests`, described in the test as a ceiling to notice rather than a rule — raising it is a
deliberate edit, and 014 already plans to make one.

**Rationale**: length is a failure mode and not merely a cost. An agent told six things at once
follows the first two, and the failure is silent — the lines that stop working are the ones nearest
the end, and nothing reports it. The three lines here come to roughly 900 characters; 014's is
roughly 300. So the first line to join already meets the ceiling, which is the point: growth should
require somebody to decide.
