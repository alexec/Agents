# Contract: what the window looks like

The app's contract is with the person using it, so this is what is on screen and what each part
promises. Three columns, `NavigationSplitView(sidebar:content:detail:)` (research §8).

```text
┌──────────────┬────────────────────────────┬──────────────────────────────┐
│ Projects     │ Agents in the project      │ The conversation             │
│              │                            │                              │
│ ▸ api      ● │ Needs input                │  (ChatView, unchanged, with  │
│   web        │   Fix the parser         ● │   002's inspector on its     │
│   docs       │ Working                    │   right when that lands)     │
│   toy        │   Write the migration    ◐ │                              │
│              │   Update the README      ◐ │                              │
│ Archived ▸   │ Completed                  │                              │
│              │   Add the index test    ✓  │                              │
│              │   Rename the module     ⨯  │                              │
│              │ ▸ Archived (12)            │                              │
└──────────────┴────────────────────────────┴──────────────────────────────┘
  280–420pt      300–460pt                    the rest
```

## The sidebar — `ProjectListView`

- Lists live projects, newest activity first (FR-015).
- A row is the project's disambiguated name, and a mark when any of its agents needs the user
  (FR-016). The mark is driven by the daemon's `counts.needsInput`, so it is right for projects that
  are not selected.
- A missing folder is marked as such and its row is dimmed. It stays selectable.
- The row's help text is the tilde-abbreviated full path.
- "Archived" is a disclosure at the bottom, listing archived projects with when they were archived.
  Unarchive from the row's menu; archive from a live row's menu.
- The toolbar keeps the "New agent" button. With a project selected, it starts in that project's
  folder without asking again (FR-006 scenario).
- Empty: the same first-run guidance the app shows today — what a runtime is, or pick a folder and
  say what you want done. Not an error.

## The panel — `ProjectAgentsView`

- Shows the selected project's agents under "Needs input", "Working", "Completed", in that order
  (FR-019), each group omitted when empty (FR-023).
- A row is `AgentRow` as it is today. In "Completed" it also says how it ended — finished, stopped,
  or the error — which is `EndedReason` it already carries (FR-022).
- Agents move between groups as their state changes, with the selection following the agent, not the
  row position (FR-024, FR-027). Animated, because a row that teleports is a row you lose.
- Below the groups, a disclosure: "Archived (n)". Turning it on lists the most recently archived
  first, ten at a time, with "Show more" while more exist (FR-028 to FR-030). The state of that
  disclosure is remembered (FR-032).
- A project with no agents says what to do rather than showing three empty headings.

## The detail — `ChatView`

Unchanged. Same transcript, prompt bar, controls, cost and usage (FR-026). This feature moves it
across a column boundary and does not touch it.

## What the window remembers

`UserDefaults`, app-side, not the daemon (research §9):

| Key | Holds |
|---|---|
| `selectedProjectFolder` | The project to select at launch. Falls back to the most recently active when it is gone or archived (FR-018). |
| `showsArchivedAgents` | Whether the panel's archived disclosure is open (FR-032). |
| `showsArchivedProjects` | Whether the sidebar's archived disclosure is open. |

## What `AppModel` gains

```swift
private(set) var projects: [ProjectSummary] = []
var selectedProject: URL? { didSet { … } }   // persisted, drives the panel
var selection: UUID?                          // unchanged, drives the conversation

func agents(in project: URL, group: AgentGroup) -> [Agent]
func addProject(_ folder: URL) async
func archiveProject(_ folder: URL) async
func unarchiveProject(_ folder: URL) async
```

`agents(in:group:)` filters the agent list it already holds by `cwd` and group, ordered newest
first. The archived list's "show more" is a count in the view, not a fetch.

## Accessibility and keyboard

- Each column is reachable with tab; each list with arrows, as sidebars are today.
- A group heading is a heading to VoiceOver, so the three groups can be jumped between.
- A row that needs the user says so in its accessibility label, not only with a dot.
- Archive and unarchive are in the context menu and the app menu, both with the selection as target.
