# 069 · Wireframes: Outcome, Steps and Details

**Approved by Alex, 2026-09-29: frames A–F**, with the recommended answer to each question below
(state held until the chat is left, phone details in place, live line hidden while steps are
open). Built on `agents/turn-detail`; see [../spec.md](../spec.md). Not built: ⌘] from frame D.

Source: [wireframes.html](wireframes.html). Open it with `#a` to `#e` to see one frame (E holds both phone frames). The PNGs
beside it are rendered from it with headless Chrome.

## What a turn is today

I read main at ca477c51 on 2026-09-29. `TurnView` has three levels. A click anywhere on a block
moves it to the next one.

| Level | What it draws |
|---|---|
| concise | the ask, your answers, the latest block, and the text before it when that block is a tool call |
| normal | the ask, your answers, every tool line and every message |
| verbose | normal, with every tool call opened: its input and its output |

| # | What goes wrong | Where |
|---|---|---|
| 1 | Some things show at no level: the agent's report, a failure or a stop, an error notice, a plan, a compaction, a model switch, a handoff, a background task, thinking. `ChatTurn` keeps only tool calls, messages, sandbox failures and answers. | `OutcomePage.swift`, `isBlock` |
| 2 | A turn that fails without a last message ends on its last tool line. It looks as if it just stopped. | same |
| 3 | View ▸ Show Thinking does nothing. Thoughts never count as blocks. | `Transcript.swift:17` |
| 4 | The click has no control you can see: no chevron, no count, no label. On the phone there is no hover help either. | `TranscriptRows.swift:88` |
| 5 | Going from normal back to concise passes through verbose. On a turn with 60 calls, that is every input and output at once. | `Detail.next` |
| 6 | The tap sits on selectable text, so selecting part of a reply is likely to change the level. | `TranscriptRows.swift:91` |
| 7 | A new turn puts the one before it back to concise, including one the reader has opened and is reading. The page moves under them. | `ChatTranscript.swift:117` |
| 8 | The level is per turn only. Nobody can say "show me steps" once for the whole chat. | — |

## The proposal in one paragraph

Each turn shows its **outcome**: what was asked, what you answered, what the agent said at the
end, and how it went (its report, or the failure). Between the ask and the outcome sits one quiet
line, **"12 steps"**, which opens the turn's **steps** in place: one line per tool call, the
agent's words between them, plans, warnings, model switches. Each step line opens its own
**details**: the input and the output of that call. View ▸ Turns sets which of the three a turn
starts at, for every chat. Opening or closing a turn by hand holds until you change it again.

## The three levels

| | Outcome | Steps | Details |
|---|---|---|---|
| The ask, your answers | ✓ | ✓ | ✓ |
| The last thing the agent said | ✓ | ✓ | ✓ |
| The report, a failure, a stop, an error notice, a sandbox failure | ✓ | ✓ | ✓ |
| While running: the latest step, as one live line | ✓ | ✓ | ✓ |
| Tool lines, the words between them, plans, warnings, switches, compaction, handoff, background tasks | | ✓ | ✓ |
| Each call's input and output | | | ✓ |
| Thinking | | | ✓ |

Details as the default opens every call of every turn. That is today's verbose, and it is there
for someone who asks for it. Nobody is sent to it by a click any more.

## The frames

| Frame | What it shows |
|---|---|
| [A](wireframes.html#a) | Mac, Outcome, the default. Three turns: one finished, one failed, one running. |
| [B](wireframes.html#b) | Mac, the middle turn with its steps open. Each step line opens its own details. |
| [C](wireframes.html#c) | Mac, one step open to its details, and thinking shown as a step. |
| [D](wireframes.html#d) | Mac, View ▸ Turns. Show Thinking goes. |
| [E](wireframes.html#e) | Phone, Outcome, with the steps row sized for a finger. |
| [F](wireframes.html#e) | Phone, steps open and one call's details. The ··· menu has the same Turns choice. |

## The rules the frames follow

1. **The steps row is the only thing that opens a turn.** Message text never toggles anything, so
   selecting and copying works everywhere.
2. **The row says how many.** "12 steps" when closed, "Hide steps" when open. It is not shown
   when a turn has no steps beyond its outcome.
3. **A running turn's live line sits under the steps row.** It is the latest step, in the
   secondary colour, and it is replaced by the outcome when the turn ends.
4. **A failure looks like a failure at every level.** The heading is in the failure tint, and the
   reason is below it in the agent's own words, or the runtime's.
5. **The report is the last line of every finished turn.** It is drawn as the app's note, not as
   the agent talking, the same pair the row in the list shows (FR-015).
6. **A step line opens itself.** It has no chevron: the margin is a run of plain lines (#112).
   On the Mac the line brightens under the pointer.
   An open call shows its input, then its output, clipped to 12 lines with "Show all".
7. **Nothing closes a turn that someone opened.** A new turn starts at the default level. The one
   before it stays as it is.
8. **The default is per app, not per project.** It sits in View ▸ Turns on the Mac and in the chat's
   ··· menu on the phone. It changes what an unopened turn shows. A turn opened or closed by hand
   keeps its own state until the chat is left.

## Questions for Alex

- **Where does a turn's own state live?** In these frames, a turn opened by hand stays open until
  you leave the chat. It could instead be remembered per conversation.
- **Should a step's details open in place on the phone, as in F, or on a page of their own?** In
  place keeps one way of doing it on both. A page gives long output the whole screen.
- **Should the running turn's live line be hidden when its steps are open?** In B it is, because
  the same line is then the last step.
