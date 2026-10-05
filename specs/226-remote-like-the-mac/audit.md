# The Remote beside the Mac (#226)

Alex asked on 2026-10-04 for the iPhone and iPad apps (the Remote) to match the Mac app,
starting with the sidebar. This page has two parts. The first says what the sidebar now
shares and what it still lacks. The second lists where the other screens differ.

Each line is marked one of three ways:

- **same**: the two apps behave alike.
- **by design**: they differ on purpose, and the line says why.
- **to do**: a gap to close later.

The audit comes from reading the code on `agents/re-enhancements-lane-started`, based on
main at 28884102. Nothing in it has been walked on a device.

## The sidebar (built in this branch)

Both apps draw from the same model in `AgentsKitCore/Sidebar`:

- `SidebarProjectFold` decides what goes under each heading, in what order, and what a
  search leaves.
- `SidebarOrder` sets the order of projects and their names.
- `SidebarFolds` holds which folds are open, and keeps them.
- `SidebarItem` is what the sidebar has picked.

The views stay separate for each platform.

The Mac's sidebar on the shared model, walked on a scratch window: Pinned above Done, the unread counts, and the Archived fold loading its page when opened (`window-sidebar.png`).

| What | Status |
|---|---|
| Activity at the top: Events, Resources, Runtimes, Spending, with plain titles (#155) | same |
| Projects in the Mac's order: this Mac's, then each server's, named `server:Project` (#145) | same |
| A project folds open on its pinned pages, Pinned sessions, live groups and Archived sessions, then Workflows and Archived workflows (#145, #180, #181) | same |
| Each group and Workflows fold. A folded group keeps its count and unread count, and a folded Needs you keeps the attention tint (#181) | same |
| Working rows stay where they are when opened: newest started first (#182) | same: the order comes from the shared `ProjectShelf` |
| Unread is a mark: a dot and a heavier title, plus an "N unread" count on the heading and project row (#70) | same |
| Labels and worktree names on the row's second line (#68) | same |
| Folds kept across launches, with projects and Archived starting folded and groups starting open | same rules. Each device keeps its own folds, because a fold records where one screen was left. |
| Archived sessions: a page of 50 while the fold is open, the host's count on its heading, the retired line last (#165, 051) | same. The count on the heading is the host's, which reaches the Remote (#227 checked it and closed with no change). |
| Search filters after a pause; an archived match shows the first 10 a fold, then Show all; one capped page is asked of the host (#176) | same, except More matches… is **to do** on the Remote. It asks the paired Mac only, not each server. |
| A project row opens its Dashboard | same. New Session is in the Dashboard's toolbar, the row's long-press menu and its leading swipe. |
| Context menus | **by design**: a long press gives the Mac's menu, and swipes do the common actions. Sessions swipe Pin/Unpin from the leading edge, and Archive (a long swipe), Bring Back and Mark as Read/Unread from the trailing edge. Workflows swipe Archive/Bring Back. |
| Session menu items Branch, Retire Now… and Show in Finder; project menu items Project Settings, Archive and Show in Finder | **by design**: these are the Mac's. The phone has no settings, and no Finder. |
| ⌘-click to pick several, ⌫ to archive, the arrow keys | **by design**: not on a touch screen. **to do**: an iPad with a keyboard could have them. |
| Reorder pinned sessions and pinned pages | **by design**: Move Up/Move Down in the long-press menu, as the Remote already did (#180). The rows also have the Mac's `onMove`, but whether a drag works on iOS outside edit mode is unchecked. |
| The foot: connection, hosts offline, store notes (#205), *Keeping this Mac awake* | **to do**: the Remote shows the stale banner and greys offline hosts, but has no foot lines. Store notes are #223. |
| Gone server projects with Remove, and a clone in progress | **by design**: adding and removing projects is the Mac's |
| New project (+) | **by design**: choosing a folder on the Mac is a feature of its own (see `ProjectRow.swift`) |
| Web page | partly: the sidebar matches from 760 px wide. Below that it still steps through one column at a time (#235). |

## Chat turn display

| What | Status |
|---|---|
| Concise turns, Outcome/Steps/Details (069), queued prompts as bubbles (#95), long chat first open (#91) | same: shared `Shared/UI/Chat` |
| Default turn level | **by design**: View ▸ Turns on the Mac, the ··· menu on the Remote, kept per device |
| Show in Changes on an edit | **by design**: the Remote has no Changes pane. Changes is a sheet, and also in Files. |
| A background task's output | **to do**: the Mac opens it, and the Remote can't open it at all |
| In-flight marks name who is being told (#87) | **to do**: the Remote always says "your Mac", which is wrong for an agent on a server |
| Jump to the message something came from (Exchanged) | **to do** on the Remote |
| The current plan pinned over the chat | **to do** on the Mac: only the Remote has the strip |
| Panes | **by design**: the Remote has no Browser, because local servers listen on the Mac only. Background is a sheet there. |
| Resource links in a reply | **by design**: the phone names them but can't open them |
| A file the agent wants you to see | **by design**: a strip on the Remote, opened straight in the pane on the Mac |

## Prompt bar

| What | Status |
|---|---|
| Attachments, dictation, slash commands, @ mentions, mode and model pills, sandbox, context meter, cost limit, Stop, the queue, drafts, warm-up | same |
| Attach by drag or paste | **to do** on the iPad. The phone picks from Photos and Files, by design. |
| Raise the limit | **by design**: on the Mac only; the phone has no settings |
| Cancel a wait from its row | **to do** on the Remote. Opening a resource from its row is the Mac's, by design (FR-011). |
| A background task's output from its row | **to do** on the Remote |
| Move a working agent to another worktree (053) | **to do** on the Remote |
| Runtime name on the bar | **to do**, minor |
| Words offered from elsewhere (`offeredPrompt`) | **to do** on the Remote |
| Labels | **by design**: in the bar on the Mac, and a strip under the title on the phone |
| Suggested prompt | **by design**: Tab on the Mac, a chip on the phone (031) |

## Dashboard

| What | Status |
|---|---|
| Tiles, Update now, Move Up/Down/to Section, Hide, Remove, Open Keeper, page tiles | same |
| Drag tiles and sections | **by design**: the long-press menu on the phone (#147) |
| Move Section Up/Down | **to do** on the Remote |
| Show Hidden Tiles | **to do** on the Remote: a hidden tile can't be brought back from the phone |
| Tile Details… (source, keeper, last values, history; FR-035) | **to do** on the Remote |
| Layout | **by design**: numbers two across and tables cut to five rows on a phone |
| An HTML pinned page shown as source | **to do** on the Remote. Show in Finder is the Mac's, by design. |

## Settings

| What | Status |
|---|---|
| General, Agent Runtimes, Shared, Spending, Resources, Control plane | **by design**: the phone has no settings. It has read-only stand-ins: Runtimes (with Assess), Spending ("set a limit on the Mac") and Resources ("declare on the Mac"). |
| Runtime sign-in and accounts | **by design**: the Mac's |
| Project Settings | **by design**: the Mac's |

## Start sheet (new session)

| What | Status |
|---|---|
| Runtime chooser (Available / Out), options, worktree, sandbox, labels, attachments, drafts per project | same |
| A sheet on the phone and the prompt bar in place on the Mac | **by design** (029) |
| Choose a folder | **by design**: the phone starts in a project already chosen |
| Reach: extra folders and servers | **to do** on the Remote |
| Pick up a conversation the runtime already holds | **to do** on the Remote |
| Sign in from the chooser | **by design**: the Mac's |
| Dictation, slash commands and @ mentions in the start field | **to do** on the Remote |
| A sandbox refusal card with Start without | **to do**, minor: the Remote says it in words |
| No runtime on a server | **to do**: the Remote says "None set up on the Mac" for a server project too |

## What Alex should try on the iPhone and iPad

- **iPad:** the sidebar beside the detail. Check that its rows, groups, folds, pins, order,
  unread marks, labels and workflows match the Mac row for row. Picking a session puts its
  chat in the detail, with no project page in between.
- **iPhone:** the same list as the root screen. Tap a session, workflow or pinned page and
  it pushes; Back returns to the list, and tapping the same row opens it again.
- **Swipes:** Pin from the leading edge, Archive from the trailing edge (a long swipe
  archives), Mark as Unread on a Done row, and Bring Back in Archived sessions. New
  Session is a leading swipe on a project row.
- **Folds:** fold a group, Pinned, Workflows and a project, then quit and relaunch. They
  should stay as you left them.
- **Archived sessions:** open the fold on a project with archived sessions. It should list
  them, and a search should find archived matches. If a project with archived sessions shows no fold, reopen #227 and say when it happened.
- **From outside the app:** open from a notification banner or the widget. The chat should
  open, and Back should return to the list.
