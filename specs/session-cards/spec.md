# A simpler set of session cards (#5026)

**Status:** spike; the open choices wait for Alex. Epic #4925. No product code: this spec, two pages and the stories.
**Clients:** none in the spike. The build is Core: the Mac window, the Remote and the web page.

## What Alex asked for

Alex (2026-11-12): "an improvement and simplification of all the different cards that appear in a session, because there just seem to be loads of different types of cards."

## The pages

- [`wireframes.html`](wireframes.html): every card the chat draws today, in the order a person sees them: about 40 kinds, and 7 kinds of question card. Each has its trigger and its source file. Section H gives the Mac and Remote differences.
- [`proposal.html`](proposal.html): the five families, each new card beside the cards it replaces.

Both pages use Paper v2 (#4926, `design/tokens.json`): Atkinson Hyperlegible Next and Mono, the v2 colours, no shadow on a card, no gradient, and no colour fill. They also use the colours of #5016: yellow for "needs you", orange for a warning, red for a failure.

## The five families

| Family | What it is for | Place | Shape | Replaces (wireframe numbers) |
|---|---|---|---|---|
| **Strip** | The session's place is not right: host, folder, account, allowance, limit | Top, one at a time, "+N more" | Well, orange glyph, one line, at most 2 buttons and ⋯ | 1–5, 36, H1 |
| **Line** | The record: what happened | Transcript | No box: glyph, bold head, quiet detail, one action link | 9, 12–14, 16 (settled), 20–22, 34 |
| **Object** | A thing the agent made, to open | Transcript | Raised box, preview, name, kind, ⋯, › | 17, 18, 19 (frame), H2 |
| **Ask** | The person must answer before the agent goes on | End of chat, under "Waiting for you" | Raised card, yellow left edge, fixed head and foot, one body | 15, 16 (raisable), 19 (asks), 26–28g, 30, 31, 33p, and the secret-use card of #4918 |
| **Now** | What the agent works towards (top) or does and waits on (foot) | Goal and plan at the top; one card above the prompt bar | Well, mark, line, meta, bar, chevron | 6, 7, 14, 25, 29, 32, 33, 35 |

Messages (bubbles) are not cards. Sheets and overlays (8, 38–40) are controls, not cards.

## Rules for every family

1. **One colour, one meaning (#5016).** Yellow (`tint.attention`) is only on an Ask's left edge and the "Waiting for you" label. Orange (`tint.warning`) is a Strip's glyph. Red (`tint.failure`) is a failed Line's glyph and words. The accent is for links, bars and the primary button. Colour never fills a card (Paper v2): it is in the text, the icon and a line.
2. **Buttons.** The primary button is filled, on the right. One more button is next to it. All other actions are in ⋯. Every Ask has the same two links: "No thanks" and "No, because…".
3. **An answer becomes a Line.** An answered Ask leaves "Waiting for you". The transcript gets one Line: "You chose ‹option›", or "Answered on another device".
4. **Keys.** Return presses the primary button of the first Ask. ⌘1–9 picks an option on the Mac (the web: see the open choices).
5. **One look on all three clients.** The same tokens, the same order of parts, the same words from the shared word files. The phone changes only the width. Under 480 pt, the buttons go under the words.
6. **Icons.** Each glyph on the pages is a stand-in for its Lucide icon (#4976, `design/icons.json`).

## Decisions

- Decided: five families, not four, because a picture in an unboxed Line reads badly. Alex can overrule.
- Decided: an Ask's mark is a yellow left edge, not a wash, because a wash on each of several cards is loud and Paper v2 never fills with colour. Alex can overrule.
- Decided: a Strip's glyph is orange (a warning), never yellow, also for the cost limit, because #5016 keeps yellow for a request; the Strip says what is wrong and its button fixes it. Alex can overrule.
- Decided: the secret-use card of #4918 (Ask before use) is an Ask, with the secret's name as the title and Allow / Deny as the foot. Alex can overrule.
- Decided: messages (bubbles) are not a family. They keep the dashed edge for "not sent yet". Alex can overrule.

## Open choices (Alex)

Asked of Alex on 2026-11-12. The answers go here.

1. **The cost limit's place:** the top Strip (recommended), or next to the prompt bar as today. *Waiting for Alex.*
2. **The three asks in the transcript** (sandbox failure, policy stop, app view): move them to "Waiting for you" (recommended; a new layout, so those PRs wait for Alex's approval, #3474), or keep them. *Waiting for Alex.*
3. **Keys on the web:** keep ⌥1–9 (recommended; the browser takes ⌘1–9), or ⌘1–9 where the browser lets it. *Waiting for Alex.*
4. **Order of the build:** the two bugs, then Ask, Now, Strip, Object, Line (recommended); or Now first; or the small families first. *Waiting for Alex.*

## How this fits the work in flight

| Work | What it changes | How the cards use it |
|---|---|---|
| Paper v2, #4926 (Mac done: #4984, #4999, #5013, #5019; Remote and web: #4992, #4993, #4996) | Tokens, font, Lucide icons, components | Every family is drawn with them. A family's story on the Remote or web goes after that client's Paper v2 story where they touch the same views. |
| #5016, PR #5017 | Yellow for needs you, orange for warnings; it changes `WaitCard`, `PolicyStopCard`, `SandboxFailureCard`, `GuardedChangeCard`, `ArchiveRequestCard`, `DesktopControlPauseCard`, `KeptPromptRow`, `PromptBar` | The Ask, Strip, Line and Now stories change the same files, so they are blocked by #5016. |
| #5022 (running) | A waiting mark for each kind of wait, and the wait line in plain words | The Now card at the foot draws the wait; it uses #5022's marks and words, so the Now story is blocked by #5022. |
| #4918 (merged, PR #5014) | The secret-use card (Ask before use) in the chat | One more Ask; the Ask story takes it. |
| #4990 (merged, PR #4994) | A question card missing in Needs you after a restart | The Ask keeps the same data; nothing to change. |

## The build

Each family is one story for all three clients (Core), a child of #4925, blocked by this spike. The two bugs have no milestone and are not blocked: they are bugs today.

| Issue | Kind | Blocked by |
|---|---|---|
| #5028 Web: the confirm card shows no question (28g) | bug | — |
| #5029 Web: the account move strip has no style (4) | bug | — |
| Ask: one card for every ask | story | #5026, #5016 |
| Now: goal and plan at the top, one card at the foot | story | #5026, #5016, #5022 |
| Strip: one strip at the top | story | #5026, #5016 |
| Object: one card for what the agent made | story | #5026 |
| Line: one shape for the record | story | #5026, #5016 |

The order between the stories follows Alex's answer to choice 4.

## Approval

A story that adds a screen, control or layout waits for Alex (#3474). The Ask story waits when the three asks move (choice 2). The Strip story waits when the cost limit moves (choice 1). The Now story waits, because it joins five cards into one at the foot. Line and Object change only the look of what is there; they say `Approval: not needed` unless the lane finds otherwise.
