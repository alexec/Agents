# Wireframe: Agentic Workflows

Layout first. Nothing here is settled until it has been run, but this is the shape the spec and plan imply, and the place to argue with it is before `/speckit-tasks`.

Two surfaces only. The spec puts authoring in the file or in the agent (FR-032), so there is no editor, no detail page and no run-history view to draw.

---

## 1. The project page

Workflows sit **below** the agent groups and **above** archived. The reasoning: you come to a project page to see what is happening, and workflows are what *will* happen. Putting them first would push "needs you" under the fold on any project with a few standing arrangements.

Same 144pt gutter as everything else on the page, same `GroupHeading` as the agent groups, same card spacing.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                                                                              │
│      Agents                                                                  │
│                                                                              │
│      ┌────────────────────────────────────────────────────────────────┐      │
│      │  Say what you want done…                          [Claude ▾]   │      │
│      └────────────────────────────────────────────────────────────────┘      │
│                                                                              │
│      Needs you  1                                                            │
│      ╭────────────────────────────────────────────────────────────────╮      │
│      │ ●  Rewrite the settings sheet                                  │      │
│      │    Waiting for your answer                                     │      │
│      │    Claude · step 3 of 7                                        │      │
│      ╰────────────────────────────────────────────────────────────────╯      │
│                                                                              │
│      Working  2                                                              │
│      ╭────────────────────────────────────────────────────────────────╮      │
│      │ ◐  Check the build                                             │      │
│      │    Running the test suite                                      │      │
│      │    Claude · from Morning build check                           │      │◄── FR-019
│      ╰────────────────────────────────────────────────────────────────╯      │
│      ╭────────────────────────────────────────────────────────────────╮      │
│      │ ◐  Tidy the daemon's error codes                               │      │
│      ╰────────────────────────────────────────────────────────────────╯      │
│                                                                              │
│      Done  4                                                                 │
│      ╭────────────────────────────────────────────────────────────────╮      │
│      │ ○  Read a form the way the protocol sends one                  │      │
│      ╰────────────────────────────────────────────────────────────────╯      │
│                                                                              │
│                                                                              │
│      Workflows  4                                                            │
│      ╭────────────────────────────────────────────────────────────────╮      │
│      │ ◷  Morning build check                             [▶] [🗄]    │      │
│      │    Every weekday at 9:00am, in a new agent                     │      │
│      │    Next at 9:00am tomorrow · Ran 20 minutes ago →              │      │
│      ╰────────────────────────────────────────────────────────────────╯      │
│      ╭────────────────────────────────────────────────────────────────╮      │
│      │ ◐  Review what just finished              [Running…]  [🗄]     │      │
│      │    When an agent finishes, in a new agent                      │      │
│      │    Started 40 seconds ago →                                    │      │
│      ╰────────────────────────────────────────────────────────────────╯      │
│      ╭────────────────────────────────────────────────────────────────╮      │
│      │ ◷  Standup notes                                   [▶] [🗄]    │      │
│      │    Every day at 5:30pm, in its own standing agent              │      │
│      │    Next at 5:30pm today · Ran yesterday →                      │      │
│      ╰────────────────────────────────────────────────────────────────╯      │
│                                                                              │
│      ▸ Archived  12                                                          │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Row anatomy

Three lines, deliberately the same three `AgentRow` already uses, so the page has one way of describing a thing rather than two:

| Line | Font | Carries |
|---|---|---|
| 1 | `.headline` | The workflow's name |
| 2 | `.callout` `.secondary` | **What it is** — the trigger and mode in plain language (FR-027) |
| 3 | `.caption` `.tertiary` | **What is happening** — next fire, and the last outcome (FR-028) |

The trailing controls are real glass buttons rather than a context menu, because unlike an agent card the row is not itself a destination and the two actions are the point of it. They are **icons carrying tooltips**, not labelled buttons: the row repeats down the page, and *Run now* set in text on every one of them is the loudest thing on the page — louder than the workflow names. The words are in the tooltips and in the context menu, which is where somebody goes when a symbol is not enough. Running it is always offered, on every row, including unsupported ones and ones over a ceiling (FR-012); an archived row offers `Restore` and nothing else, because offering to run a thing that will not run is offering a lie.

`→` on the third line is the link to the agent that run started or resumed (FR-029).

### Why the cards are not buttons

An `AgentCard` is a button because the whole card opens that conversation — "a real control, which is what earns it interactive glass". A workflow has no conversation to open. Making the card a button would need a destination invented for it; a run already has one and it is on line 3.

---

## 2. Every state a row can be in

This is the part worth arguing over, because user story 3 lives here entirely.

```
  RUNS ON A SCHEDULE, IDLE
  ╭────────────────────────────────────────────────────────────────╮
  │ ◷  Morning build check                        [▶] [🗄]         │
  │    Every weekday at 9:00am, in a new agent                     │
  │    Next at 9:00am tomorrow · Ran 20 minutes ago →              │
  ╰────────────────────────────────────────────────────────────────╯

  REACTS TO AGENTS, NO SCHEDULE — no "next", because there isn't one
  ╭────────────────────────────────────────────────────────────────╮
  │ ◷  Review what just finished                  [▶] [🗄]         │
  │    When an agent finishes, in a new agent                      │
  │    Ran 3 times today · last 12 minutes ago →                   │
  ╰────────────────────────────────────────────────────────────────╯

  RUNNING NOW
  ╭────────────────────────────────────────────────────────────────╮
  │ ◐  Review what just finished              [Running…]  [🗄]     │
  │    When an agent finishes, in a new agent                      │
  │    Started 40 seconds ago →                                    │
  ╰────────────────────────────────────────────────────────────────╯

  ARCHIVED — grey, because nothing is wrong and nobody is needed
  ╭────────────────────────────────────────────────────────────────╮
  │ 🗄  Dependency advisories                          [Restore]    │
  │    Every weekday at 9:00am, in a new agent                     │
  │    Archived — it will not run                                  │
  ╰────────────────────────────────────────────────────────────────╯

  REFUSED, SELF-RESOLVING — grey. It will sort itself out.
  ╭────────────────────────────────────────────────────────────────╮
  │ ◷  Morning build check                        [▶] [🗄]         │
  │    Every weekday at 9:00am, in a new agent                     │
  │    Next at 9:30am · Did not run — a run is still going         │
  ╰────────────────────────────────────────────────────────────────╯

  REFUSED, REPEATEDLY — one line with a count, never fourteen rows (FR-030)
  ╭────────────────────────────────────────────────────────────────╮
  │ ◷  Standup notes                              [▶] [🗄]         │
  │    Every day at 5:30pm, in its own standing agent              │
  │    Next at 5:30pm today · Missed 14 times — the app was closed │
  ╰────────────────────────────────────────────────────────────────╯

  REFUSED, NEEDS A PERSON — the loop will not stop on its own next time
  ╭────────────────────────────────────────────────────────────────╮
  │ ⚠  Review what just finished                  [▶] [🗄]         │
  │    When an agent finishes, in a new agent                      │
  │    Did not run 3 times — this chain is already 3 deep          │
  ╰────────────────────────────────────────────────────────────────╯

  CANNOT BE READ — needs a person, and says exactly where
  ╭────────────────────────────────────────────────────────────────╮
  │ ⚠  deploy-check                               [▶] [🗄]         │
  │    This file could not be read                                 │
  │    Line 3: mapping values are not allowed here                 │
  ╰────────────────────────────────────────────────────────────────╯

  FROM THE FUTURE — not broken. A file written against a later version.
  ╭────────────────────────────────────────────────────────────────╮
  │ ◌  Watch the deploy                           [▶] [🗄]         │
  │    Waits for "deploys-finished", which this version does not   │
  │    know about yet                                              │
  ╰────────────────────────────────────────────────────────────────╯
```

### The colour rule

The app's existing rule is that grey is everything and "the only colour in this app means something needs a person". Applied here, that draws a line straight through the refusal list:

| Grey | Coloured |
|---|---|
| Archived · a run is still going · missed while closed · running · idle | The chain limit was reached · a ceiling is full · the file cannot be read · the folder is gone |

A refusal that will resolve itself is information. A refusal that will keep happening until somebody does something is the only kind that earns the colour. Getting this backwards — colouring every refusal — would make the page shout about a workflow skipping one fire and would spend the colour the app reserves for agents waiting on an answer.

### Empty state

```
      Workflows  0

      No workflows yet. A workflow is a prompt that runs itself — on a
      schedule, or when an agent finishes. Ask an agent to set one up, or
      write one into .agents/workflows.
```

Says where the files live, because that is the one fact nobody can guess, and names both routes to a first workflow.

---

## 3. Archiving, which replaced the confirmation

There is no confirmation. A write used to raise one — the daemon's own sheet, in front of the writing, blocking the tool call on it — and it is gone. It failed in both directions: it put a prompt nobody had asked to read in front of a decision with a quick wrong answer, and with no window open there was nobody to ask, so an agent working overnight could not write a workflow at all.

The say is after the fact instead, on the row, where there is something to look at:

```
  ╭────────────────────────────────────────────────────────────────╮
  │ ⏱  Dependency advisories             [▶] [🗄]                 │
  │    Every weekday at 9am, in a new agent                        │
  │    Next tomorrow at 9:00 · Ran 2 days ago →                    │
  ╰────────────────────────────────────────────────────────────────╯

  ARCHIVED — under its own heading, folded away, and never fired.
      ▸ Archived  2

      ▾ Archived  2
  ╭────────────────────────────────────────────────────────────────╮
  │ 🗄  Watch the deploy                              [Restore]     │
  │    Every day on the hour, in a new agent                       │
  │    Archived — it will not run                                  │
  ╰────────────────────────────────────────────────────────────────╯
```

- **Archiving is not deleting.** The file stays in the project, reviewable and committable like any other file; the app simply stops acting on it. Deleting an agent's work on the strength of one tap would be the harder thing to undo.
- **It folds away rather than disappearing.** A page that hid archived workflows entirely would leave somebody hunting for one the app had swallowed.
- **An archived row has one control, and it is the way back.** Run now beside something that will not run is an offer the app cannot keep.
- **An agent writing to an archived id does not un-archive it**, and is told so. A veto the agent it was aimed at can lift is not a veto.

### The ceilings

Three live workflows to a project, and ten across all of them. The agent is refused a fourth outright, naming the three in the way. A fourth written by hand is listed and inert rather than hidden:

```
  ╭────────────────────────────────────────────────────────────────╮
  │ ⚠  Watch the queue                            [▶] [🗄]        │
  │    Every day on the hour, in a new agent                       │
  │    This project already runs its 3 workflows. Archive another  │
  │    in this project to let it run                               │
  ╰────────────────────────────────────────────────────────────────╯
```

The total ceiling reads the same way, with the one difference that matters: *10 workflows are already running, across every project. Archive one, in any project, to let it run.* A remedy in a project you are not looking at has to say so, or the row is a puzzle.

They earn the colour, unlike a skipped fire: nothing resolves them on their own. And the section says the rule under the list before anybody walks into it — a ceiling nobody can see is a ceiling somebody walks into.

---

## What this wireframe is not showing, and why

| Not drawn | Because |
|---|---|
| A workflow editor | FR-032 — authoring is the file or the agent, not the app |
| A run history view | Every run is an agent, and the agent list already shows those |
| A workflows tab or sidebar entry | Workflows belong to a project; the project page is where a project's things are |
| Per-workflow chain-depth settings | A runaway workflow able to raise its own limit is not stopped |
| Notifications when a workflow refuses | Out of scope for this version (spec, Assumptions) |

---

## The three things most worth arguing with

1. **Workflows at the bottom of the page.** The alternative is directly under the prompt bar, which makes them impossible to miss and pushes "needs you" down. I think what is happening beats what will happen, but a project with two agents and nine workflows would read the other way.
2. **Trailing icon buttons instead of a context menu.** Every other card on this page hides its actions in a context menu. Two visible buttons per row is heavier, and is what stops running a workflow by hand — the thing you need when testing one you just wrote — from being a right-click nobody finds. As icons they cost a tooltip's worth of discoverability and save the row from shouting; if the two symbols turn out not to read, labels come back and the names go quiet some other way.
3. **Colouring only the refusals that need a person.** The conservative alternative colours every refusal. That is louder, and it spends the one signal this app reserves for "a person is needed" on a workflow skipping a single fire.
