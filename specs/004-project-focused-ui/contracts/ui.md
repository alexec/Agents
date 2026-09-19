# Contract: what the window looks like

The app's contract is with the person using it, so this is what is on screen and what each part
promises. Three columns, `NavigationSplitView(sidebar:content:detail:)` (research §8).

```text
┌──────────────┬────────────────────────────┬──────────────────────────────┐
│ Projects     │ Agents in the project      │ The conversation             │
│              │                            │                              │
│ ▸ api      ● │ ★ Project lead        ◐    │  (ChatView, unchanged, with  │
│   web        │ ───────────────────────    │   002's inspector on its     │
│   docs       │ Needs input                │   right when that lands)     │
│   toy        │   Fix the parser         ● │                              │
│              │ Working                    │                              │
│ Archived ▸   │   Write the migration    ◐ │                              │
│              │ Completed                  │                              │
│              │   Add the index test    ✓  │                              │
│              │ ▸ Archived (12)            │                              │
└──────────────┴────────────────────────────┴──────────────────────────────┘
  280–420pt      300–460pt                    the rest
```

## The sidebar — `ProjectListView`

- Lists live projects, newest activity first (FR-015).
- A row is the project's disambiguated name, and a mark when any of its agents needs the user
  (FR-016). The mark is driven by the daemon's `counts.needsInput` **or** `leadNeedsInput`, so a lead
  waiting on a permission marks its project too (FR-045), and it is right for projects that are not
  selected.
- A missing folder is marked as such and its row is dimmed. It stays selectable.
- The row's help text is the tilde-abbreviated full path.
- "Archived" is a disclosure at the bottom, listing archived projects with when they were archived.
  Unarchive from the row's menu; archive from a live row's menu.
- The toolbar keeps the "New agent" button. With a project selected, it starts in that project's
  folder without asking again (FR-006 scenario).
- Empty: the same first-run guidance the app shows today — what a runtime is, or pick a folder and
  say what you want done. Not an error.

## The panel — `ProjectAgentsView`

- **The lead is pinned at the top**, above "Needs input", in its own row with a rule under it, and
  appears in none of the three groups (FR-043). Its row shows the same state marks as any agent, so a
  working or waiting lead reads at a glance.
- Selecting a project selects its lead, so picking a folder opens the conversation about that folder
  (FR-044). Picking a worker afterwards moves the detail to it; the lead stays pinned.
- Shows the selected project's workers under "Needs input", "Working", "Completed", in that order
  (FR-019), each group omitted when empty (FR-023).
- A row is `AgentRow` as it is today. In "Completed" it also says how it ended — finished, stopped,
  or the error — which is `EndedReason` it already carries (FR-022).
- Agents move between groups as their state changes, with the selection following the agent, not the
  row position (FR-024, FR-027). Animated, because a row that teleports is a row you lose.
- Below the groups, a disclosure: "Archived (n)". Turning it on lists the most recently archived
  first, ten at a time, with "Show more" while more exist (FR-028 to FR-030). The state of that
  disclosure is remembered (FR-032).
- A project with no workers shows the lead and says what to do — which is now "tell the lead what you
  want done" rather than "start an agent" — instead of three empty headings.
- The lead's row has no archive action. Its context menu offers stop, and nothing that would remove it
  (FR-046).

## The detail — `ChatView`

Unchanged for workers: same transcript, prompt bar, controls, cost and usage (FR-026). This feature
moves it across a column boundary and does not touch it.

For a lead it is the same view. What a lead does to other agents arrives as ordinary tool calls in the
transcript, and the permission questions it raises are the ordinary permission questions, so the chat
view needs nothing new to show a lead working. An agent a lead started is an ordinary agent, so it
opens the same way (FR-041).

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

func lead(of project: URL) -> Agent?
func workers(in project: URL, group: AgentGroup) -> [Agent]
func addProject(_ folder: URL) async
func archiveProject(_ folder: URL) async
func unarchiveProject(_ folder: URL) async
```

`workers(in:group:)` filters the agent list it already holds by `cwd`, role and group, ordered newest
first; `lead(of:)` is the same filter for the one `.lead`. The archived list's "show more" is a count
in the view, not a fetch.

## Accessibility and keyboard

- Each column is reachable with tab; each list with arrows, as sidebars are today.
- A group heading is a heading to VoiceOver, so the three groups can be jumped between.
- A row that needs the user says so in its accessibility label, not only with a dot.
- Archive and unarchive are in the context menu and the app menu, both with the selection as target,
  and both absent for a lead.
- The lead's pinned row is announced as the project lead, not as an agent called "lead", so it is
  clear what it is without seeing the star.
