# Session labels: wireframes

These show where a label goes and what it says, not a new destination. A label is a chip on
a card, a row, a chat header, a form and a menu. The Mac frames and the phone frames show
the same session: a Claude agent called **Tidy the perf suite**, working, labelled `perf`
by Alex and `spike` by the agent itself.

A filled chip is Alex's, an outlined chip is the agent's. The two are told apart by the
fill and not only by colour (FR-006).

## 1. Mac: a card and a row in the sessions list

```text
┌──────────────────────────────────────────────────────────────┐
│ agents                                                       │
│                                                              │
│ Working                                                      │
│ ┌──────────────────────────────────────────────────────────┐ │
│ │ Tidy the perf suite                        ● working     │ │
│ │ (perf) (spike)                                              │ │
│ │ Claude · asked to cut the suite from 4m to 2m            │ │
│ └──────────────────────────────────────────────────────────┘ │
│                                                              │
│ Needs you                                                    │
│ ┌──────────────────────────────────────────────────────────┐ │
│ │ Ship the export button                       ⏸ waiting   │ │
│ │ (urgent) (blocked)                                         │ │
│ │ Codex · the export needs a column that is not there yet  │ │
│ └──────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

`(perf)` is filled, because Alex put it there. `(spike)` is outlined, because the agent did.
The chips sit under the title, above the runtime line, so the title stays one line and the
last thing the agent said stays the thing the card is read for.

The filter is at the top of the sessions list, beside the search field, and takes the same
text the search does:

```text
│ [ Search sessions…                       ]  [ Filter: label:perf ▾ ] │
└──────────────────────────────────────────────────────────────────────┘
```

Typing `label:perf` in the search field does the same thing, and the two combine: `perf
suite` finds the sessions labelled `perf` whose title or last line mentions a suite.

A filter that matches nothing says so, and offers to clear itself:

```text
│ No sessions labelled “urgent-fix”                             │
│ [ Clear filter ]                                             │
```

## 2. Mac: the new-session form

```text
┌──────────────────────────────────────────────────────────────┐
│ New Claude agent                                             │
│                                                              │
│ [ Ask Claude to work on this project…                    ]    │
│                                                              │
│ Runtime [Claude ▾]    Mode [Ask for approval ▾]              │
│                                                              │
│ Labels                                                        │
│ [ perf                                      × ] [ Add label ] │
│ In this project:  spike · blocked · urgent · perf            │
│                                                              │
│                                         [Cancel] [ Start]     │
└──────────────────────────────────────────────────────────────┘
```

Everything Alex has added sits above, with a ✕ on each. The line under is the project's
labels in use, so `perf` does not arrive as `Perf` as well (FR-004). A sixth label is
refused where it is typed, with the reason, and nothing else on the form changes:

```text
│ A session can have 5 labels. Remove one to add another.       │
```

## 3. Mac: the label menu on a card

Opened from the card's menu, next to **Show in Finder**.

```text
┌──────────────────────────────────────────┐
│ Tidy the perf suite                       │
│                                          │
│ Labels                                    │
│   (perf) (spike)                    [✕]   │
│   [ Add label…                        ]   │
│                                          │
│ In this project:  blocked · spike · urgent │
└──────────────────────────────────────────┘
```

Choosing **Add label…** gives a field that matches the project's labels as Alex types, and
marks the ones the session already has rather than offering them again.

Every label here can go, whichever owner it has. Alex's `perf` and the agent's `spike` have
the same ✕, because from here they do (FR-009).

## 4. Mac: the chat header

```text
┌──────────────────────────────────────────────────────────────┐
│  ‹ agents                                                    │
│                                                              │
│  Tidy the perf suite                          (perf) (spike)  │
│  Claude · working · asked 4 minutes ago                      │
│                                                              │
│  The suite is down to 2m. The two slow tests are the …       │
└──────────────────────────────────────────────────────────────┘
```

The header carries every label, not a count, since there is room for it. Clicking a chip
opens the same menu as the card's, and removing one from here takes it off the card at once
(FR-020, FR-023).

## 5. Phone and iPad

A card shows at most two chips and counts the rest (FR-021). The menu and the header show
all of them.

```text
┌──────────────────────────────┐
│ Working                  2  │
│                              │
│ Tidy the perf suite          │
│ (perf) (spike) +1            │
│ ● working · 4m               │
│                              │
│ The suite is down to 2m. T…  │
└──────────────────────────────┘
```

```text
┌──────────────────────────────┐
│ ‹ agents                     │
│                              │
│ Tidy the perf suite           │
│ (perf) (spike) (slow)         │
│ Claude · working              │
│                              │
│ The suite is down to 2m. T…   │
│                              │
│ [ Ask a question…        ]   │
└──────────────────────────────┘
```

```text
┌──────────────────────────────┐
│ Labels                    ✕  │
│                              │
│ (perf) (spike) (slow)        │
│ [ Add label…              ]  │
│                              │
│ In this project:             │
│  blocked                     │
│  urgent                      │
└──────────────────────────────┘
```

The new-session form carries the same **Labels** line as the Mac's, under the runtime and
mode pickers, and the same suggestion line.

## 6. What an agent is told

The chip shapes carry the rule, so an agent can see who owns a label without asking. When
it tries the wrong thing, the call says why in a sentence it can act on (FR-017):

```text
Agent: finish_turn(labels: { remove: ["perf"] })
App:   “perf” is Alex's label on this session. You can only remove labels an agent added.
       The session still has: perf (Alex), spike (this agent).
```

and, when the agent adds a label the person already has:

```text
Agent: finish_turn(labels: { add: ["perf"] })
App:   “perf” is already on this session as Alex's label. Nothing changed.
       The session still has: perf (Alex), spike (this agent).
```

The refusal is not a failure. The turn carries on, and the person reading it afterwards
sees the reason in what the agent said (FR-017, US 3 scenario 5).

## 7. Colour

Two colours, not one per label. Alex's chip is filled in the accent colour, and the agent's
is outlined in the same accent. A card with five labels is two colours, and the two owners
still read apart in greyscale and to a screen reader, which says "Alex's label" and "this
agent's label".

## Decided here, not in the spec

- A label reads `#42`, not `42`, when it stands for something numbered, so it is never read
  as a bare number. Nothing turns a label into a link.
- The suggestion line lists the project's labels without the ones the session already has,
  so adding is a choice rather than a lookup. Removing a suggestion that is already there is
  done from the chip above, not from this line.
- On the Mac, the filter is a menu that writes `label:perf` into the search field, so it can
  be edited, shared and combined by hand. Typing it works the same and nothing is hidden
  behind the menu.
