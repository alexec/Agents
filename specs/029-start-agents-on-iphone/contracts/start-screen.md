# Contract: the start screen on the remote

What the person sees and can do. The layout is settled by running it (memory: settle the UX
before building depth) and this file is corrected to match what was settled, not the other way
round.

## Where it opens

| Device | Opened from | Presented as |
|--------|-------------|--------------|
| iPhone | A "New agent" button in the project page's toolbar, always visible | A full-height sheet |
| iPad | The same button | A form sheet over the three panes |

"New agent" is the Mac's name for the action (FR-019); if the Mac's wording differs when this is
built, the Mac's wins.

## What is on it, top to bottom (iPhone)

1. **Header**: the project's name, and Cancel. Cancel keeps the draft (FR-016).
2. **Runtime**: one row, the runtime's name, opening a menu of the Mac's runtimes in the Mac's
   order. An unavailable one is listed, disabled, with the Mac's reason under its name.
3. **Choices**: one row per option `PromptControlsState.drawable` returns, in
   `ConfigOption.categoryOrder`. A select option is a menu showing its current choice's name; a
   boolean is a switch. While loading: the rows from memory if the daemon answered from its cache,
   else a single "Getting <runtime>'s choices…" row. On failure: the daemon's sentence and a Retry.
4. **Attachments**: a strip of what is attached, each removable, each showing its refusal under
   it when the runtime will not take it.
5. **Prompt**: a multi-line field that has focus when the sheet opens, grows to about six lines
   then scrolls, with an attach button (photo library, Files) and Send beside it. Send is
   disabled while the field is empty or while a send is in flight.

The choices sit above the prompt so that, with the keyboard up, the prompt and Send are what is
visible, and the choices are one scroll away without dismissing the keyboard (FR-018).

## What happens on Send

| Outcome | What the phone does |
|---------|---------------------|
| Started | Dismiss the sheet, clear the draft, open the new agent's conversation |
| Refused by the phone (stale, archived, folder gone, attachment refused, over size) | Keep the sheet and the draft, show the sentence above the prompt |
| Refused by the Mac | Same, with the daemon's `message` |
| No reply (link dropped) | Keep the sheet, show "Checking whether it started…", and settle by `startRequestID` when the link is back (research §4) |

## Accessibility

Every control has a label naming what it chooses (e.g. "Runtime, Claude Code"). The screen is
usable at the largest Dynamic Type size: rows wrap rather than truncate, and the prompt field
keeps at least two lines visible with the keyboard up.
