# Quickstart: Prompt Controls, Project Navigation, Scroll-to-Bottom, Remembered Mode, and Unseen File Requests

**Date**: 2026-09-19 | **Feature**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

There is no app test target and no snapshot test in this repository, so the unit tests hold the
pure logic and the views are checked by running the app. This is how to see each bug before the
change and each fix after it. Do the "before" pass first — three of the six causes are easy to
talk yourself out of having seen.

## Prerequisites

- macOS 27, Xcode 27, the project generated: `xcodegen generate`
- At least two runtimes installed and signed in. **Cursor is required** — it is cause 1, and it
  is the only runtime that reproduces `.nothingOffered` on its own
- An agent with a transcript long enough to scroll. Any conversation of a few dozen turns
- **At least two projects**, each with at least one conversation. Story 2 needs both

## Build and test

```sh
xcodegen generate
swift test --package-path Packages/AgentsKit
xcodebuild -project Agents.xcodeproj -scheme Agents -configuration Debug build
```

`swift test` must be green before and after. `AgentGroupTests` exists to catch an agent that
falls into two groups or none; widen it to exhaust the new input rather than relaxing it.
`ConfigOptionTests` is the existing regression suite for the option shapes and must pass
**unchanged** — if a change to `Options.swift` breaks
one of its 19 cases, the change is wrong, not the test.

The two new suites:

```sh
swift test --package-path Packages/AgentsKit --filter PromptControlsStateTests
swift test --package-path Packages/AgentsKit --filter ModeMemoryTests
```

## Story 1 — the controls under the prompt

### Before: see it break

| # | Cause | Do this | You should see the bug |
|---|---|---|---|
| 1 | Cursor advertises nothing | New chat → runtime **Cursor** → choose a folder | The area under the prompt is empty. No row, no message, no gap you can point at |
| 2 | `??` cannot fire on an empty array | Open any Cursor conversation from the sidebar | Same empty area, and no way to ask for options |
| 3 | A failed fetch looks like no options | Quit the daemon mid-fetch, or point a runtime at a folder it cannot read, then start a new chat | Empty area. The error may flash in the global banner and then there is nothing |
| 4 | Overlapping fetches | New chat → change the folder, then immediately change the runtime | Briefly the previous runtime's controls, shown as settled |
| 5 | Revive blanks the saved options | Not reliably reproducible by hand. Covered by reading `DaemonCore+Commands.swift:283`; see research §1 | — |
| 6 | The row is wider than the pane | **This is the one to do.** Open a Claude chat, open the sidebar, drag it wider than **407pt** in the default 1100pt window | The model and thought-level controls go off the right edge with no indication |

For cause 6 the measured numbers are in [research.md §1.6](./research.md). Claude's new-chat row
is 405pt and needs a 693pt conversation pane. At the default 380pt sidebar there is **27pt of
headroom**. At the narrowest conversation the app allows (520pt) the row overflows by 173pt.

### After: each case says what it is

1. **Cursor, new chat** → "Cursor has nothing to adjust." The prompt still sends.
2. **Cursor, existing conversation** → the same line. Not an empty gap.
3. **No folder yet** → "Choose a folder to see what this runtime offers." Choose one and the
   message becomes the fetching line, then the controls.
4. **Fetching** → "Asking Claude what it offers…" — the existing line, now one case of six.
5. **A failed fetch** → the reason, and a retry. Press it; it fetches again without restarting
   the chat or the app.
6. **Narrow pane** → drag the sidebar to 900pt, its maximum. The conversation is at its 520pt
   minimum and the options row scrolls horizontally. Every control is still reachable. The row
   no longer right-aligns the model and effort controls — that is the deliberate trade in
   [plan.md](./plan.md), not a regression to report.
7. **Change the folder then the runtime quickly** → the row that settles is the one for the
   runtime you ended on, every time.

## Story 2 — clicking a project takes you to the project

### Before: see it break

1. Open a conversation in project A. Note that A is highlighted in the sidebar.
2. Click A — the highlighted row. **Nothing happens.** You are still on the conversation.
3. Click it again. Still nothing. This is the bug.
4. Now click project **B**. It works: you land on B's page. That contrast is the whole
   diagnosis — the binding only fires on a change, and re-picking the row you are on is not one.

### After

1. Conversation in A open → click A in the sidebar → A's project page, first click.
2. Conversation in A open → click B → B's project page. This worked before and must still work.
3. Already on A's project page → click A → nothing changes, nothing flickers, and anything
   typed in the prompt is still there.
4. Conversation open → move through the project list with the arrow keys → each project's page
   appears as you land on it, **including the one you started in**.
5. Conversation open → use the back control in the toolbar instead → exactly as before. This
   feature adds a route; it removes none.
6. Click a project → the prompt on that page is already pointed at that project's folder.
7. **The one to watch**: start an agent working in A, open its conversation, then click A while
   it is mid-turn. The turn must carry on untouched — go back in and it is still going, with
   nothing lost from the transcript (FR-025).

### If the gesture is swallowed

`simultaneousGesture` on a sidebar `List` row is the documented way to see a click on an
already-selected row, but SwiftUI sidebars have eaten gestures before. Check all three at once:
the click works, the selection highlight still moves, and the right-click context menu (Archive,
Show in Finder) still opens. If any of those broke, take the fallback in
[research.md §2](./research.md) — the row becomes a `Button` and `List(selection:)` keeps only
the highlight.

## Story 3 — the controls answer at once

### Before

Open a conversation with a **live** agent — one mid-turn is best, because that is when the
runtime is slowest to answer. Change its mode. The menu closes and the capsule still reads the
old value, for as long as the runtime takes. On a busy Claude session that is long enough to
click again.

Then do the same on a **new** chat, where there is no agent yet. It is instant. That contrast
is the diagnosis: the draft branch of the binding writes somewhere the getter reads, and the
agent branch does not.

### After

1. Live agent, change the mode → the capsule reads the new value before the menu has finished
   closing.
2. Same, with the agent mid-turn → the choice stays on screen for the whole wait. No revert,
   no re-arrival.
3. Change the same control twice quickly → it ends on the second choice, whatever order the
   answers come back in.
4. An on-or-off option → same behaviour.
5. New chat with no agent → exactly as before, still instant.
6. **The one to watch**: stop the daemon, then change an option. The control must not sit
   showing a value that never took — the problem is reported and the control settles back on
   what is in force.
7. Watch for a flicker: the optimistic value is dropped when the call returns, on the argument
   that the daemon broadcasts the change before it responds. If you see the capsule snap back
   and forward, that argument is wrong on this machine and the fallback is in
   [research.md §5](./research.md).

## Story 4 — getting back to the end

### Before

Open a long conversation, scroll well up, and note: nothing offers to take you back, nothing
tells you the agent has said anything since, and sending a prompt leaves you where you are —
`Transcript.swift:63` guards the auto-scroll on `isAtEnd`, so your own prompt scrolls away from
you rather than to you.

### After

1. Scroll up in a long conversation → a button appears above the prompt. Press it → the last
   line, clear of the prompt bar.
2. Already at the end → no button.
3. A conversation too short to scroll → no button, at any window size.
4. Scroll up and let the agent work → you stay where you are reading, and the button says there
   is something new. Press it → the end, and the "new" indication clears. Scroll back down by
   hand instead → it clears that way too.
5. Scroll up and send a prompt → the view returns to the end and your prompt is there.
6. **View → Jump to Latest**, or its shortcut, with the pointer nowhere near the button → the
   end of the conversation.
7. Scroll to the very top of a long transcript so earlier history loads → you stay on the line
   you were reading, and the button is still offering the end. This is the regression to watch:
   loading earlier must not read as new content arriving.

## Story 5 — the mode you chose last time

### Before

Start a chat with Claude, change the mode away from its default, send something. Start another
new chat with Claude. The mode is back to the runtime's default.

### After

```sh
# Look at what is stored. Nothing here before the first change.
defaults read com.alexecollins.Agents | grep 'prompt.mode'
```

1. New Claude chat → change the mode → start it. The key appears.
2. Another new Claude chat → the mode control already reads what you chose.
3. Quit the app, reopen it, new chat → still remembered.
4. New chat with a **different** runtime → that runtime's own default, no error, and its own
   key once you change it there. Two runtimes, two keys, no bleed.
5. Change the mode on a **running** conversation → only that conversation changes, and the next
   new chat with that runtime opens on the new choice.
6. **Staleness**: put a nonsense value in by hand and start a new chat —

   ```sh
   defaults write com.alexecollins.Agents 'prompt.mode.claude' -string '"no-such-mode"'
   ```

   The runtime's own default is used, no error is shown, and the agent does **not** start in
   some other mode. This is the one that matters: getting it wrong starts an agent with
   permissions nobody chose.
7. **Cursor** → advertises no mode, so nothing is remembered and nothing breaks.

## Story 6 — an agent that wants you to look

### Before: see it break

1. Start an agent in project A and ask it something that will make it open a file —
   "show me where X is defined" usually does it.
2. While it works, open a conversation in project **B**.
3. The agent in A calls `show_file`. **Nothing happens anywhere.** No mark on the agent, no dot
   on project A in the sidebar.
4. Read the agent's reply. It says the file is open in the pane beside the conversation. It is
   not, and the person has no way to know it was ever asked for.

### After

1. Same setup → the agent in A appears under **Needs attention** on A's project page, and A
   carries the sidebar dot.
2. Open that conversation → the file opens in the pane and the mark clears in the same moment.
3. Have an agent show a file in the conversation you are **already** looking at → the file
   opens as it always did, and no mark appears. It has already had your attention.
4. **The one to watch**: a marked agent must still read as working. Its card sits under "Needs
   attention" but its own line still says "Working" with the spinner, because its state has not
   changed. Check that this does not read as a contradiction — if it does, the card needs a
   line saying *why* it is there, not a change of state.
5. Send a prompt to a marked agent from elsewhere → it queues, or does not, exactly as it would
   for any working agent. Nothing about `hasTurnInFlight` moved.
6. Let a marked agent finish its turn before you look → the mark stays. The file is still worth
   showing.
7. Quit and reopen the app with a mark outstanding → it is gone, and that is correct. The
   daemon stores nothing and already refuses to show a file when no window is open.

## Story 7 — answering in one click

### Before

Get an agent to ask a question with a short list of answers. Note the radio group and the Send
button: two clicks to say one word. Then compare it with a permission question from the same
agent — already one click, on buttons, in the agent's own words.

### After

1. A question whose whole answer is one choice → clicking a choice sends it and the question
   goes. One click.
2. It reads like a permission question: the agent's wording on buttons.
3. A choice with an explanation under it → the explanation is still there. This is the point of
   the comment already in the view; a bare row of words loses what separates two choices.
4. An optional single choice → there is still a one-click way to give no answer, and it is
   still distinct from "No thanks".
5. "No thanks" → still declines, still one click, still not the same thing as answering with
   nothing.
6. A form with **two or more** fields → unchanged, radio group and Send. Check this one: a
   partial answer must not become sendable.
7. Free text, a number, a multi-select → unchanged.
8. A question with many choices, or one very long choice → the buttons must stay reachable in
   the 144pt gutter, the same problem §1.6 measured for the options row.

## Clean up

```sh
defaults delete com.alexecollins.Agents 'prompt.mode.claude'
```

## What "done" looks like

- `swift test --package-path Packages/AgentsKit` green, `ConfigOptionTests` unchanged
- All six control-area cases seen in the running app, including Cursor's
- Clicking the already-highlighted project takes you to its page, with the highlight and the
  context menu both still working
- The options row reachable with the sidebar at 900pt
- The jump-to-end button absent on a short transcript and present on a long one
- An option control on a live agent reading the new value on the same frame as the click
- A remembered mode surviving a quit, and a stale one discarded without a word
- An agent that shows a file to a window looking elsewhere marked as needing attention, still
  reading as working, and cleared by opening its conversation
- A one-choice question answered in one click, and a two-field form still needing its Send
