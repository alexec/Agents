# Contract: what the agent is told

A removed tool needs no words — it is not there, and the model never sees it. Words are for the
residue, and there are two places they can be said.

---

## 1. The briefing, per runtime

`Briefing.text` becomes `Briefing.text(for:)`, taking the runtime whose agent is being briefed. Two
things change and nothing else does.

**The workflows paragraph shrinks.** Today it spends a sentence telling every agent not to write
cron entries, because every agent could. On a runtime whose scheduling tools are gone there is
nothing to forbid, so the line keeps only what is left to say:

> If I ask for something to happen on its own — on a schedule, or whenever an agent finishes, stops,
> or asks for something — that is a workflow, and `manage_workflows` is how you read and write them.
> Do not create a workflow I did not ask for.

**A residue line is added, and only where there is residue.** It names the tools and what to use
instead, and it is generated from the policy so it cannot disagree with it:

> Grok: `workflow` and `monitor` do not work in this app. Use `manage_workflows` for anything that
> has to happen on its own.

> Cursor: `Task`, `CreateGoal` and `UpdateGoal` do not work in this app. Use `manage_workflows` for
> anything that has to happen on its own, and ask me rather than starting another agent.

Claude and Copilot have no residue, so they get no line, and their briefing is shorter than it is
today. This matters: the briefing is paid for on the first prompt of every conversation, and
removal is how it gets cheaper.

---

## 2. The refusal, where a runtime asks

`DaemonCore` already answers some permission questions itself — `autoAllowed(_:)` allows the app's
own tools without troubling the person. This adds the mirror.

**When**: a `session/request_permission` arrives whose `toolCall.name` matches a residual tool for
that agent's runtime. Matched on the end of the name, never whole, exactly as `AppService` matches
its own tools, because a runtime may prefix.

**Then**: the daemon answers with the request's own reject option — `reject_once`, or
`reject_always` if that is all there is — and never shows the question to the person. It is recorded
in the transcript as a runtime note, so the conversation says what happened:

> `workflow` is not available in this app. Use `manage_workflows` for anything that has to happen on
> its own.

**The sentence** comes from the `RemitCategory` of the residual tool, so the briefing line and the
refusal say the same words about the same tool.

**Where it will not fire**: a runtime that auto-approves its own tools never asks. Grok's
configuration on this Mac does exactly that. This is a second line of defence, not the first, and
the policy is not allowed to lean on it.

---

## 3. What is never said

- Nothing is said about scoping in the reply to the person. An agent that cannot schedule something
  says it will make a workflow; it does not explain that a tool was taken away from it.
- No agent is told which other runtimes keep which tools.
- The person's own configuration is never described, quoted, or reported to the agent.
