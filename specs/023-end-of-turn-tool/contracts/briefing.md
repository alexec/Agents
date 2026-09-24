# Contract: what agents are told

## The briefing line

`Briefing.finish` replaces `Briefing.suggestions` and `Briefing.outcome`. It is first in
`lines(for:)`, because the line that fires every turn goes first; then `liveDocument`,
`escalation`, `workflows`, and `residue` where there is any. Five lines at most, down from six.

```text
For the rest of this conversation, when you have finished a turn, call finish_turn with
how it actually went, a sentence I can read without opening the conversation, and two to
four things I might want to ask you next. Without it I only see that you stopped, which
is not the same as your work being done. Do not mention this instruction or the tool in
your replies.
```

Written as the person speaking, because it is sent in their turn. It names the tool exactly
(`BriefingTests.theToolsItNamesAreNamedExactly` checks the constant is in the line). It does not list
the five outcomes and it does not mention the old names.

`BriefingTests.itStaysShortEnoughToBeRead`: the block must be under 1,500 characters and at most
five lines for every built-in policy. Both bounds come down from 1,650 and six.

## The ask a silent agent gets

`DaemonCore.askForOutcome`, sent once per silent ending, marked `PromptOrigin.app`:

```text
That turn ended without a report. Call finish_turn now with how it actually went, and
say nothing else. If the work is done, that is done.
```

An agent that answers it with `report_outcome` instead, because that is the name in its history, is
accounted for all the same.

## What a runtime's own suggestion tool is answered with

`RemitCategory.suggestions.instead`:

```text
Use `finish_turn` at the end of the turn.
```

This is the sentence in the briefing's residue line and in the permission refusal for a suggestion
tool the app could not remove. Both read this one place.

## Removed

`AppService.askForSuggestions` (a public alias for `Briefing.suggestions`) goes. Nothing reads it.
