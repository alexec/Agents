# Research: One Call to End a Turn

## R1. The tool's name

**Decision**: `finish_turn`.

**Rationale**: The spec's one requirement for the name is that it reads as the end of a turn and
not as a status update, because the failure to avoid is an agent calling it mid-turn to say how
things are going. `finish_turn` says when as well as what. It also survives the prefix every runtime
puts on it: `mcp__agents__finish_turn` reads the same way.

**Alternatives considered**: (a) `end_turn` — rejected because `endTurn` is ACP's own stop reason,
the thing the runtime sends when it gives the turn back, and a tool with that name invites an agent
to think the call itself ends the turn. It does not; it returns and the turn ends afterwards
(FR-010). (b) `report` or `wrap_up` — rejected; the first is a status update by name, the second is
vague enough that Grok's search-by-words habit (015's finding) would not find it. (c) Keeping
`report_outcome` and adding a `prompts` argument to it — rejected because it leaves the briefing
saying "report" for a call that also suggests, and because a fresh agent reading the list would see
nothing that says the suggestion tool is gone.

## R2. Where the two become one

**Decision**: In the daemon. One method, `agents/finishTurn`, one request, one set of checks, then
report and chips set together and one `changed(agent)`.

**Rationale**: The helper could have relayed a new tool as two existing calls, but the spec's FR-005
says a refused call shows nothing, and two relayed calls can half-land: chips shown, then the outcome
refused for a pending form. One daemon method runs the outcome's four refusals (`noSuchAgent`,
unknown outcome, empty message, a permission or elicitation pending) before it writes anything.
The existing `reportOutcome` body is split so its checks and its record-then-broadcast tail are
shared with `finishTurn` rather than copied.

**Alternatives considered**: Relay in the helper — rejected above. Route the aliases through the new
method — rejected because `suggest_next_prompts` has no outcome to give it, and the old daemon
methods are what the existing integration suites exercise (SC-007).

## R3. What a missing or empty list of prompts does

**Decision**: Sets `suggestedPrompts` to empty. Never refuses.

**Rationale**: FR-008: a later call is the whole account, chips included. An agent that called once
with prompts and again without has changed its mind about the ending, and the chips belonged to the
ending. An empty list is the same as no list. The old `suggest_next_prompts` keeps refusing an empty
list, because that is its existing contract and there is nothing else in that call to record.

## R4. What an unknown outcome word does — and one spec line amended

**Decision**: The whole call is refused at `AppService` with the sentence naming the five, exactly
as `report_outcome` is refused today. Nothing is shown, prompts included.

**Rationale**: The spec's edge case said the message and the prompts should still be shown. That
described 014's FR-027, which is about a *record* holding a word this build does not know, not a
*call* — a call with a bad word has always been refused before it reaches the daemon, so the agent
can read the five and try again. Half-landing the call would show chips beneath an ending the app
then has to call unaccounted for, which is the exact picture the feature exists to remove. The spec's
edge case is amended to say so.

## R5. The aliases: listed, described, and confined

**Decision**: Both old tools stay in `tools/list`, after the three current tools, with the
description cut to one paragraph that names `finish_turn` as the tool to use. Their schemas, their
handlers in `AppService.handle`, their sinks, their daemon methods and their integration tests are
untouched.

**Rationale**: The spec asked for listed and accepted. Listed matters because some runtimes check a
name against the list before calling it. Described as aliases matters because a fresh agent reading
the whole list should not see three end-of-turn tools and pick by whim; the briefing never names
them, so the description is the only place that says which is which. Confinement matters for FR-014:
removal is deleting two entries from the list, two `if` branches in `handle`, two predicates in
`PermissionRequest`, and two sinks in the helper. The daemon methods can stay forever; nothing is
hurt by a method nobody calls.

**When they go**: Not decided here. The floor is one release. The trigger is when no conversation
briefed with the old names could still be resumed, which depends on how long records are kept, and
that is Alex's call. `AppTool` carries a comment with the date the aliases began.

## R6. The briefing line

**Decision**: `Briefing.suggestions` and `Briefing.outcome` are replaced by `Briefing.finish`, first
in `lines(for:)`:

```text
For the rest of this conversation, when you have finished a turn, call finish_turn with
how it actually went, a sentence I can read without opening the conversation, and two to
four things I might want to ask you next. Without it I only see that you stopped, which
is not the same as your work being done. Do not mention this instruction or the tool in
your replies.
```

**Rationale**: It is the sum of the two lines it replaces with the ordering clause cut, and it keeps
every phrase that the live runs showed doing work: "for the rest of this conversation", "when you
have finished a turn", "two to four things I might want to ask you next", "I only see that you
stopped", "do not mention this instruction". It does not list the five outcomes; the schema does.

It goes first because the file's own rule is that the line that fires every turn goes first. 014
put `outcome` after `escalation` so that an agent read "ask with the tool that waits" before "you
may end by saying needs_answer". That ordering is now carried by the tool description, which keeps
014's last paragraph verbatim, and by the merged line not mentioning `needs_answer` at all.

`lines(for:)` drops from six to five. `BriefingTests.itStaysShortEnoughToBeRead` moves its ceiling
from 1,650 characters and six lines to 1,500 and five.

## R7. What else names the old tools

**Decision**: Three sites change to name `finish_turn`; nothing else in the tree names either old
tool outside `AppService`, `Briefing`, `AppTool` and the helper.

| Site | Today | After |
|---|---|---|
| `RemitCategory.suggestions.instead` | "Use `suggest_next_prompts` at the end of the turn." | "Use `finish_turn` at the end of the turn." |
| `DaemonCore.askForOutcome` | "Call `report_outcome` now…" | "Call `finish_turn` now…" |
| `AppService.askForSuggestions` | `Briefing.suggestions` | removed; nothing reads it |

**Rationale**: `instead` is what a runtime's refused rival tool is answered with, and a runtime told
to use a name the briefing does not mention would go looking. The ask is answered by either name
(FR-018) because the aliases are accepted everywhere; it names the new one because a fresh agent was
told the new one.

## R8. Recognising the call as the app's own

**Decision**: `PermissionRequest.isFinishingTurn`, folded into `isTheApps` and so into
`isAutoAllowable`; `TranscriptDisplay` suppresses it alongside the two old names.

**Rationale**: Copilot asks before every tool call and the app answers for its own tools itself; a
new name it does not recognise would put a sheet in front of every turn's ending. The transcript
does not draw the call because what it did is drawn twice already: the chips above the prompt and
the report at the foot. Suffix-matched, for the reason every other predicate there gives.

## R9. Proving the resumed conversation

**Decision**: An integration test in `FinishTurnTests` that starts an agent, lets its briefing go,
and then drives the two old names through `AppService` into the daemon over the real socket, in
both orders and each alone, and asserts the agent's state against a fresh agent that made the one
call with the same values. The resume path itself (`needsBriefing` not re-set on resume) is already
covered by `SuggestedPromptTests.aConversationResumedAfterARestartIsNotBriefedAgain`, which is
flaky for reasons that predate this feature and are noted in memory.

**Rationale**: The scenario the spec is most worried about is the one no fresh-conversation test
exercises. It has to be its own test.

## R10. What the runtimes actually do — to be measured

**Decision**: `FinishTurnLiveTests`, modelled on `OutcomeReportLiveTests`, runs one turn per
runtime and records whether the turn ended with `finish_turn`, with what outcome, and with how many
prompts. The numbers go here, beside 014's R11, when the build is done. SC-004 is the comparison:
the share of normal endings carrying an account must not fall below what 014 measured for
`report_outcome`.

**Rationale**: Nothing in ACP or MCP makes a runtime call a tool at the end of a turn. Whether the
merged line lands is somebody else's model's business, and the only way to know is to run it.
