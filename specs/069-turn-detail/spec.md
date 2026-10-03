# Feature Specification: Outcome, Steps and Details

**Feature Branch**: `agents/turn-detail`

**Created**: 2026-09-29

**Status**: Look approved 2026-09-29 ([look/](look/README.md), frames A–F)

**Input**: A review of how a session is shown ("does it seem natural and correct? Think about the
concise/standard/verbose options"). The review found eight faults, listed in
[look/README.md](look/README.md#what-a-turn-is-today).

## Clarifications

Alex answered the look's three questions on 2026-09-29. He took the recommended answer each time:

- A turn opened or closed by hand keeps that state **until the chat is left**. Nothing is stored.
- On the phone, a step's details open **in place**, the same as on the Mac.
- While a turn runs with its steps open, the **live line is hidden**, because the last step says
  the same thing.

## What changes

Each turn is drawn at one of three levels. The chat no longer cycles through them on a click.

| | Outcome | Steps | Details |
|---|---|---|---|
| The ask, and the person's answers | ✓ | ✓ | ✓ |
| The reply: the last thing the agent said | ✓ | ✓ | ✓ |
| How it went: the report, a stop or a failure, an error notice, a sandbox failure | ✓ | ✓ | ✓ |
| While running, the latest step as one live line (steps closed) | ✓ | | |
| Every other drawn item, one line each, in order | | ✓ | ✓ |
| Each tool call's content, input and output, opened | | | ✓ |
| Thinking | | | ✓ |

## Requirements

- **FR-001** A turn's **outcome** is its answers to questions, its reply, and every item that says how it went:
  a work report, a stopped state, an error notice, a sandbox failure. It is drawn at every level.
- **FR-002** The **reply** is the run of agent messages at the end of the turn, after its last
  step; a closing line said after the report joins it. A finished turn that ends on a step has its
  last agent message as the reply. A running turn with no trailing message has none: its latest
  step is the live line. The report is drawn last. A permission choice is a step, not an outcome.
- **FR-003** A turn with steps has one control between the ask and the outcome. It reads
  "N steps" when closed and "Hide steps" when open: the words alone, with no chevron (#148). N counts each tool call and
  each other step line. Thinking is not counted. A turn with no steps has no control.
- **FR-004** The control is the only thing that opens or closes a turn. Message text is never a
  tap target, so it can be selected.
- **FR-005** When open, the turn is drawn in transcript order. Each tool call is its own line, by
  the description the agent gave it (`turnLine`), and opens its own content, input and output.
  Thinking is drawn only at Details.
- **FR-006** At Details, every tool call starts open.
- **FR-007** The app has one default level for every chat: View ▸ Turns on the Mac, and a "Turns
  show" section of the chat's ··· menu on the phone. It is stored per app, and on the Mac per
  root, as appearance is. View ▸ Show Thinking is removed. Its key is read once: someone who had
  it on starts at Details.
- **FR-008** Opening or closing a turn by hand overrides the default for that turn until the chat
  is left. A new turn never changes an earlier turn's state.
- **FR-009** A stored turn (`turns.jsonl`) carries its outcome entries and its step count, so it is
  drawn from its summary until opened. A summary written by an older build is brought up to date
  from the transcript when it is read, as `concise` was. An older client keeps reading `concise`
  and `last`.
- **FR-010** View ▸ Turns ▸ Show Steps of This Turn (⌘]) is **not** built. The look marked its
  shortcut as a placeholder, and there is no "turn the pane is on" to aim it at yet.

## Success criteria

- **SC-001** A turn that fails with no reply ends on its failure, in the failure tint, at every
  level.
- **SC-002** A finished turn's report is on screen at Outcome.
- **SC-003** Closing an open turn takes one click, and never passes through Details.
- **SC-004** Sending a new prompt leaves an opened turn open.
- **SC-005** Walked on a scratch Mac app with a real agent turn, at each of the three defaults.
