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
│      Workflows  4                                       Pause all ⏸          │◄── FR-024
│      ╭────────────────────────────────────────────────────────────────╮      │
│      │ ◷  Morning build check                        [Run now] [⏸]    │      │
│      │    Every weekday at 9:00am, in a new agent                     │      │
│      │    Next at 9:00am tomorrow · Ran 20 minutes ago →              │      │
│      ╰────────────────────────────────────────────────────────────────╯      │
│      ╭────────────────────────────────────────────────────────────────╮      │
│      │ ◐  Review what just finished              [Running…]  [⏸]      │      │
│      │    When an agent finishes, in a new agent                      │      │
│      │    Started 40 seconds ago →                                    │      │
│      ╰────────────────────────────────────────────────────────────────╯      │
│      ╭────────────────────────────────────────────────────────────────╮      │
│      │ ◷  Standup notes                              [Run now] [⏸]    │      │
│      │    Every day at 5:30pm, in its own standing agent              │      │
│      │    Next at 5:30pm today · Ran yesterday →                      │      │
│      ╰────────────────────────────────────────────────────────────────╯      │
│      ╭────────────────────────────────────────────────────────────────╮      │
│      │ ⏸  Dependency advisories                      [Run now] [▶]    │      │
│      │    Every weekday at 9:00am, in a new agent                     │      │
│      │    Paused                                                      │      │
│      ╰────────────────────────────────────────────────────────────────╯      │
│                                                                              │
│      Show archived (12)                                                      │
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

The trailing controls are real glass buttons rather than a context menu, because unlike an agent card the row is not itself a destination and the two actions are the point of it. `Run now` is always offered, on every row, including paused and unsupported ones (FR-012).

`→` on the third line is the link to the agent that run started or resumed (FR-029).

### Why the cards are not buttons

An `AgentCard` is a button because the whole card opens that conversation — "a real control, which is what earns it interactive glass". A workflow has no conversation to open. Making the card a button would need a destination invented for it; a run already has one and it is on line 3.

---

## 2. Every state a row can be in

This is the part worth arguing over, because user story 3 lives here entirely.

```
  RUNS ON A SCHEDULE, IDLE
  ╭────────────────────────────────────────────────────────────────╮
  │ ◷  Morning build check                        [Run now] [⏸]    │
  │    Every weekday at 9:00am, in a new agent                     │
  │    Next at 9:00am tomorrow · Ran 20 minutes ago →              │
  ╰────────────────────────────────────────────────────────────────╯

  REACTS TO AGENTS, NO SCHEDULE — no "next", because there isn't one
  ╭────────────────────────────────────────────────────────────────╮
  │ ◷  Review what just finished                  [Run now] [⏸]    │
  │    When an agent finishes, in a new agent                      │
  │    Ran 3 times today · last 12 minutes ago →                   │
  ╰────────────────────────────────────────────────────────────────╯

  RUNNING NOW
  ╭────────────────────────────────────────────────────────────────╮
  │ ◐  Review what just finished              [Running…]  [⏸]      │
  │    When an agent finishes, in a new agent                      │
  │    Started 40 seconds ago →                                    │
  ╰────────────────────────────────────────────────────────────────╯

  PAUSED — grey, because nothing is wrong and nobody is needed
  ╭────────────────────────────────────────────────────────────────╮
  │ ⏸  Dependency advisories                      [Run now] [▶]    │
  │    Every weekday at 9:00am, in a new agent                     │
  │    Paused                                                      │
  ╰────────────────────────────────────────────────────────────────╯

  REFUSED, SELF-RESOLVING — grey. It will sort itself out.
  ╭────────────────────────────────────────────────────────────────╮
  │ ◷  Morning build check                        [Run now] [⏸]    │
  │    Every weekday at 9:00am, in a new agent                     │
  │    Next at 9:30am · Did not run — a run is still going         │
  ╰────────────────────────────────────────────────────────────────╯

  REFUSED, REPEATEDLY — one line with a count, never fourteen rows (FR-030)
  ╭────────────────────────────────────────────────────────────────╮
  │ ◷  Standup notes                              [Run now] [⏸]    │
  │    Every day at 5:30pm, in its own standing agent              │
  │    Next at 5:30pm today · Missed 14 times — the app was closed │
  ╰────────────────────────────────────────────────────────────────╯

  REFUSED, NEEDS A PERSON — the loop will not stop on its own next time
  ╭────────────────────────────────────────────────────────────────╮
  │ ⚠  Review what just finished                  [Run now] [⏸]    │
  │    When an agent finishes, in a new agent                      │
  │    Did not run 3 times — this chain is already 3 deep          │
  ╰────────────────────────────────────────────────────────────────╯

  CANNOT BE READ — needs a person, and says exactly where
  ╭────────────────────────────────────────────────────────────────╮
  │ ⚠  deploy-check                               [Run now] [⏸]    │
  │    This file could not be read                                 │
  │    Line 3: mapping values are not allowed here                 │
  ╰────────────────────────────────────────────────────────────────╯

  FROM THE FUTURE — not broken. A file written against a later version.
  ╭────────────────────────────────────────────────────────────────╮
  │ ◌  Watch the deploy                           [Run now] [⏸]    │
  │    Waits for "deploys-finished", which this version does not   │
  │    know about yet                                              │
  ╰────────────────────────────────────────────────────────────────╯
```

### The colour rule

The app's existing rule is that grey is everything and "the only colour in this app means something needs a person". Applied here, that draws a line straight through the refusal list:

| Grey | Coloured |
|---|---|
| Paused · a run is still going · missed while closed · running · idle | The chain limit was reached · the file cannot be read · the folder is gone |

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

## 3. The confirmation

Raised by the daemon, not the runtime, so it looks the same whichever runtime the agent is using. Shown wherever permission requests are shown today.

```
┌──────────────────────────────────────────────────────────────────────┐
│                                                                      │
│   Rewrite the settings sheet wants to add a workflow                 │
│                                                                      │
│   ┌──────────────────────────────────────────────────────────────┐   │
│   │  Dependency advisories                                       │   │
│   │                                                              │   │
│   │  Runs every weekday at 9:00am, in a new agent.               │   │◄── FR-036
│   │                                                              │   │
│   │  ──────────────────────────────────────────────────────────  │   │
│   │                                                              │   │
│   │  Check whether any of our dependencies have security         │   │
│   │  advisories published since yesterday. If any do, say which  │   │
│   │  and how bad. Do not change any files.                       │   │
│   │                                                              │   │
│   └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│   .agents/workflows/dependency-advisories.md                         │
│                                                                      │
│                                          [ Don't ]   [ Add it ]      │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

Three decisions in this one sheet:

- **The trigger is stated in words, above the prompt.** *Runs every weekday at 9:00am, in a new agent* — not YAML, not a path, not a diff. It is the same string the project-page row shows, from the same renderer, so the thing you approved and the thing you later see cannot drift.
- **The prompt is shown in full.** Approving a workflow is approving what an agent will be told, unattended, every weekday. Hiding it behind a disclosure would make the safe action the uninformed one.
- **There is no "always allow".** Deliberately absent, and worth saying out loud: an agent with blanket approval to write workflows could write a workflow that writes workflows.

The path is at the bottom, small — true, and not what the decision turns on.

### Its other three outcomes

| Situation | What happens |
|---|---|
| No window open | Nothing is written. The agent is told: *"No window is open, so there was nobody to ask."* |
| Two minutes, no answer | Nothing is written. *"Nobody answered, so nothing was written. You can ask again."* |
| Changing an existing workflow | Same sheet, headed *…wants to change a workflow*, and the summary line says what it would become |

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
2. **Trailing buttons instead of a context menu.** Every other card on this page hides its actions in a context menu. Two visible buttons per row is heavier, and is what stops `Run now` — the thing you need when testing a workflow you just wrote — from being a right-click nobody finds.
3. **Colouring only the refusals that need a person.** The conservative alternative colours every refusal. That is louder, and it spends the one signal this app reserves for "a person is needed" on a workflow skipping a single fire.
