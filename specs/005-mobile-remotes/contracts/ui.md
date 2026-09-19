# Contract: what the remote shows

The app's contract is with the person using it. Same vocabulary as the Mac, same grouping, laid out
for the screen in hand.

## The shape, copied from what 004 built

004 shipped two columns and a push, not three columns. The remote does the same, which is why the
iPhone is not a reduction of the Mac and the iPad is not an expansion of the phone — all three are
one layout at three sizes.

```text
  iPad, wide                                  iPhone / iPad narrow
┌──────────────┬────────────────────────────┐ ┌──────────────────────┐
│ Projects     │  api                       │ │ ‹ Projects           │
│              │                            │ │                      │
│ ▸ api      ● │  ┌──────────────────────┐  │ │  api                 │
│   web        │  │ what do you want…  ⏎ │  │ │ ┌──────────────────┐ │
│   docs       │  └──────────────────────┘  │ │ │ what do you…   ⏎ │ │
│              │                            │ │ └──────────────────┘ │
│              │  Needs input               │ │                      │
│              │   ┌────────────────────┐   │ │  Needs input         │
│              │   │ Fix the parser   ● │   │ │   ┌────────────────┐ │
│              │   └────────────────────┘   │ │   │ Fix the parser│ │
│              │  Working                   │ │   └────────────────┘ │
│              │   ┌────────────────────┐   │ │  Working             │
│              │   │ Write the migr…  ◐ │   │ │   ┌────────────────┐ │
│              │   └────────────────────┘   │ │   │ Write the mig…│ │
│              │  ▸ Archived (12)           │ │   └────────────────┘ │
└──────────────┴────────────────────────────┘ └──────────────────────┘
                              │ tap an agent
                              ▼
                  ┌────────────────────────────┐
                  │ ‹ api        transcript    │   a push, with a back
                  │              diffs, output │   button — not a column
                  │  [ prompt…             ] ⏎ │
                  └────────────────────────────┘
```

- **iPad, wide**: the projects column stays visible, as it does on the Mac, because moving between
  projects is the ordinary thing to do and a list that hides itself when used is one you keep
  fetching back. The conversation still pushes over the project pane.
- **iPhone, and iPad narrow**: the projects column collapses to a back destination. Everything else
  is identical.
- 002's inspector rides beside the conversation on a wide iPad only, as it does on the Mac when the
  window allows. Never on a phone.

There is **no project lead**. It was built and taken back out of 004 before this feature starts.

## What each part promises

### The project page

- Its name, then the prompt bar with this project's folder already set, then the agents. Typing what
  you want done starts an agent here and takes you into it — the same thing the Mac's project page
  does, and the reason an iPad is a place to start work rather than only to watch it.
- The path is not repeated under the name. The one case where the folder is news is that it has gone,
  and then it says so.

### Projects

- Live projects, newest activity first, named as the Mac names them — the same `ProjectNaming`, so
  two disambiguated "api" rows read identically on both.
- A row marks when any of its agents needs the user, driven by the daemon's counts, so it is right
  for projects that are not selected.
- A missing folder is marked and dimmed, and stays selectable.
- Archiving a project is **not** here. It is tidying, and tidying is a desk activity.

### Agents

- "Needs input", "Working", "Completed", in that order, empty groups omitted, from the same
  `AgentGroup` function the Mac uses. They cannot disagree because it is one file.
- Agents are cards, as they are on the Mac, in the same gutter the transcript and prompt bar use, so
  the project page and a conversation are the same width.
- Archived agents behind a disclosure, newest first, ten at a time.
- Agents move between groups as their state changes, with the selection following the agent.

### The conversation

- Transcript with diffs, command output and touched files, laid out for the screen (FR-022).
- Cost and context as reported, never estimated (FR-023).
- A prompt bar that takes text and attachments from the photo library or Files, refused before
  sending when the runtime cannot take them — the same refusal the Mac gives, for the same reason.
- History is paged. Opening shows the end of the conversation immediately and fetches backwards as
  the user scrolls (FR-037).

### The question

The thing the whole feature exists for. It shows what is being asked in full — the command, or the
change — and the same choices the Mac offers, no fewer.

When it has already been answered it says so and by which device, and puts the outcome where the
buttons were. It never offers a second answer to a settled question (FR-032).

## Being out of touch

A remote that has lost the Mac says so in one line at the top: **"Last heard from your Mac 12
minutes ago."** State below it is dimmed and marked stale, and every action is refused at the moment
it is taken rather than appearing to work (FR-033, FR-035). This is the screen the user sees when the
Mac is asleep, and it must read as information rather than as an error.

## Pairing

- **On the phone, first run**: what this is, that it needs the same Apple Account with iCloud Drive
  on, and one button. Then: "Waiting for you to approve this on your Mac."
- **On the Mac**: a question naming the device — "Alex's iPhone would like to connect" — with
  **Approve** and **Deny**. Nothing is sealed to a device before this.
- **Settings on the Mac**: each device by name, when it was paired, when it last connected, which
  notifications it wants, and **Revoke**. Revoking says plainly that the device will no longer be
  able to read anything.

## Notifications

- A permission or form arriving raises an alert notification naming the project and the agent and
  what is wanted. Tapping it opens that agent.
- Finished and failed can each be turned off, per device.
- The banner is written on the device after decrypting. If that fails the user sees "An agent needs
  you" — less useful, never wrong, and tapping it still lands in the right place.
- A notification for something already dealt with opens the agent showing what became of it, not an
  empty question (FR-018).

## Accessibility

- Every group heading is a heading, so the groups can be jumped between.
- A row that needs the user says so in its label, not only with a dot.
- The question's choices are buttons with full labels, reachable by VoiceOver in the order they are
  read, and Dynamic Type never truncates what is being asked — a permission the user cannot read in
  full is one they cannot answer.

## What the remote does not do

Start a project, archive a project, rename anything, change runtime accounts or sign in to a runtime.
Those stay at the Mac.
