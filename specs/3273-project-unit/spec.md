# The project is the unit (#3273)

At first, the app worked on a "project" that was one folder on one machine. Since #2317, a
**project** is a record on the control plane, and **folders** on many machines join it. A
folder is still one directory on one machine. Clones of one repository on three machines
are three folders in one project.

The data accepts this, but most of the app does not show it. Only the Project picker, the
Tasks, Code review and CI slots, the Project dimension in Reports and Console ▸ Projects
use the project. The sidebar, New Session, the helper limits, the agent tools and Work all
still treat the folder as the unit.

This spec makes the project the unit that people see and work in. The folder stays as the
place where the project is on one machine. It is part of `feature:projects`.

Alex chose this on 2026-11-02 (option 1), over a "group by project" switch in the sidebar
only, and over no change.

## The words

| Word | Meaning | Changes |
|---|---|---|
| **Project** | What people work on. A record on the control plane. | It becomes the sidebar's group and New Session's first choice. |
| **Folder** | One directory on one machine that is in a project. | It stays. A folder shows its machine where that is needed. |
| **Machine** | A computer that runs agents. | No change. |
| **Repo** | A Git repository on a forge. | Lineage's `project` node kind becomes `repo`, so "project" has one meaning. |

We add no new word such as "place" or "workspace". "Folder" is already the honest word for
one directory on one machine (#2313).

## What a solo person sees

Each folder is in a project of its own name, unless the person joins two folders to one
project (#2317). **A project with one folder looks the same as a folder does today:** one
group, the same name, and the same menu. A person who never joins two folders sees no
change, except that the Settings sheet is now called **Project Settings**. This is the
test for every slice.

## The sidebar (Core: Mac, Remote and web)

The sidebar has one group per **project**, not per folder. The rules for its order stay
the same: pinned projects first, then the rest. In each of the two, the projects that
have a folder on this machine come first.

```
▾ Agents                                     ◐ 3  ⚠ 1
    ● Plans lead                 · 1/6
        ◐ Plans 2: forge/plan    devbox
        ⚠ Plans 1: AGENTS.md     
    ○ Fix the sidebar fold
▾ www                                        
    ○ Copy for 0.16
▸ api            devbox                      ○ 2
```

- **A project with one folder** shows as today. When the folder is on another machine,
  its machine shows after the name (`api  devbox`), as `devbox:api` does today.
- **A project with folders on several machines** shows one group. A session that runs on a
  machine other than this one shows that machine's name at the end of its row (`devbox`).
  On the Remote and the web page, "this machine" is the machine you last used.
- **The group's menu** gets **Folders**, which lists the project's folders with their
  machine and state (online, offline, stopped), with **Open Folder** and **Folder
  Settings** for each. **New Session** in the menu starts in the project (see below).
- **Archived folders** stays a list of folders. A project whose folders are all archived
  is not in the sidebar.
- **The smart groups** (Pinned, Needs You, Working, Unread) do not change. A row there
  shows its project's name, as it now shows its folder's name.
- **The Remote** shows the groups and the machine marks. It shows the **Folders** list
  only to open a folder. Folder management stays Mac + web (#2798).

## New Session (Core: Mac, Remote and web)

New Session asks for the **project** first and the **machine** second. It no longer asks
for a folder by path.

```
New Session
  Project   [ Agents            ▾ ]
  On        [ This Mac          ▾ ]   This Mac · devbox (online) · cloud-1 (stopped, starts when used)
  Where     [ New worktree      ▾ ]
  Runtime   [ Auto              ▾ ]
  ┌──────────────────────────────────────────────────────────┐
  │ Prompt…                                                  │
  └──────────────────────────────────────────────────────────┘
```

- **Project:** the one you last started a session in, as the folder is today.
- **On:** the machines that have a folder of the project. The default is this machine
  when it has one. If it has none, the default is the machine you last used for this
  project. A stopped machine is marked "starts when used". A project with only one
  folder hides this row.
- **Add a folder on another machine** is the last item of **On**. It opens the existing
  Send to ‹machine› flow (#2929). It is not a new flow.

## Project Settings and Folder Settings (Mac + web)

**Folder Settings** becomes **Project Settings**: the settings that every folder of the
project shares. A smaller **Folder Settings** keeps only what belongs to one directory
on one machine.

What goes where follows what already travels with Git. The repository's `.agents/`
(`folder.json`, skills, personas, workflows, `mcp.json`, `policy.json`) is the same in
each clone, so it belongs to the project.

| Project Settings | Folder Settings (one folder) |
|---|---|
| **General:** name, owner, and the folders on each machine (with **Add on another machine…** and **Remove from project…**) | **General:** the path, the machine, and which project it is in (the Project picker) |
| **Tools:** the Tasks, Code review and CI slots (#2669), and the **boards** in Tasks (slice 9) | **Disk space** on this machine |
| **Work at once:** the lanes running, not archived and queued, **across the project** (slice 8) | **Worktrees** of this folder |
| **Sessions:** "Sessions may archive the sessions they started", "Archive a session when its pull request merges" | **Not committed:** anything in `.agents` that Git ignores in this folder |
| **Agent Configuration:** instructions, skills, personas, workflows, connectors and plugins in the repository's `.agents` | |

```
Project Settings — Agents
 General | Tools | Work at once | Sessions | Agent Configuration

 Name     Agents                       Owner  Alex
 Folders
   This Mac   ~/Agents                 online     [Folder Settings]
   devbox     /home/alex/Agents        online     [Folder Settings]
   cloud-1    /work/Agents             stopped    [Folder Settings]
   [Add on another machine…]
```

- **Agent Configuration** reads from one folder of the project: this machine's folder
  when there is one, or the first folder that is online. An edit is written in that
  folder. The page says "Written in ~/Agents on This Mac. Commit it so that your other
  folders get it." Folders that do not use Git (a Jira project with no repository) each
  keep their own copy, and the page lists the folders that differ.
- **The Remote** keeps no settings pages (#2798). It opens neither page.
- The sheet's menu item and shortcut (**File ▸ Project Settings…**, ⌥⌘,) do not change,
  except for the name. **Folder Settings…** is in the group's **Folders** list.

## Agent tools: scoped to the project

Today each tool says "in this folder". They become "in this project":

| Tool | Today | After |
|---|---|---|
| `list_sessions` | this folder's sessions | the project's sessions on every machine, each with its machine |
| `read_session`, `message_session`, `stop_session`, `archive_session`, `wait_for_agents` | this folder, and sessions this one started on other machines (#2887) | any session of the project, through the control plane |
| `start_session` | this folder; `machine` + `folder` (an absolute path) for another machine | this project; `machine` alone picks the project's folder there. `folder` stays for a folder in another project. |
| `manage_workflows` | this folder's workflows | the project's workflows. `runs-on` already picks the machines. |

- **Without a control plane,** a project is the folders on this one machine, and the
  tools work as today.
- **Permissions do not change.** An agent can reach only sessions that its person can
  reach. A session on another machine is reached through the control plane, as #2887
  does now.
- **This is the base for leads (#3265).** A lead must see and start the lanes of its
  epic on every machine of its project.

## Lane limits per project

- **Helpers running, Helpers not archived and Helpers queued** count across all the
  project's folders on every machine. Today each folder counts on its own, so a project
  with folders on two machines can run twice as many lanes. The values are already in
  `.agents/folder.json`, which travels with Git. Only what is counted changes.
- **The control plane keeps the count.** A machine that cannot reach the control plane
  counts its own folder alone, and says so (as the notice limits do in #2859).
- **The defaults** stay at 3 running, 5 not archived and 5 queued. Alex runs 5 to 7 lanes
  in this repo and sets that in Project Settings ▸ Work at once. The ceiling in Policy
  (1 to 10) applies per project. Policy's words change from "in each folder" to "in each
  project".
- **A lead does not count** as a lane (#3265). Its lanes do.

## Boards

The Tasks slot holds **one or more boards**. #2317 decided "one tracker per slot, until a
team needs more". Several teams that work on one repository need more.

- **A board** is a GitHub Projects (v2) board, a Jira board, a Linear team or a GitLab
  group board, with a name (the team's).
- **Work ▸ Issues and Work ▸ Features** get a board filter. An epic belongs to the board
  its issue is on.
- **Code review and CI** stay one per slot.

## Work (Mac + web)

Work's lists get a **Project** filter, from the project's Tasks and Code review slots.
The default is "All projects", as Work lists everything today. An issue or PR page shows
its project.

## Lineage: `project` becomes `repo`

Lineage's node kind `project` (`Go/internal/lineage/cost.go:23`) means a repository or a
tracker. It becomes `repo`. The wire field `LineageCostNode.project` becomes `repo`.
Reports' **Project** dimension (#2670) then means only the #2317 project. v0.x takes
breaking changes (no migration).

## Docs that are wrong now

These pages are out of date already, before this epic changes anything:

- `docs/reference/settings.md`: Folder Settings ▸ General does not list the Project
  picker.
- `docs/reference/agents-folder.md`: `folder.json`'s `project` key is not listed.
- `docs/reference/console.md`: Console ▸ Projects is not mentioned.
- `docs/reference/integrations.md:145`, `:149`: say that the Tasks, Code review and CI
  slots are the folder's.

Each slice below also changes the docs for what it changes.

## Slices (one agent and one PR each)

| # | Level | What | Clients | Blocked by |
|---|---|---|---|---|
| 1 | task | Docs that are wrong now (above) | docs only | — |
| 2 | task | Lineage `project` → `repo` (kind, wire field, client words) | Mac + web words | — |
| 3 | task | Sessions carry their project; `sessions/list` and `folders/list` give each folder's project and machine; the control plane lists a project's sessions on every machine | no | — |
| 4 | task | Agent tools scoped to the project | no | 3 |
| 5 | story | The sidebar groups by project, with machine marks and the Folders list | Core: Mac, Remote, web; `needs-approval` | 3 |
| 6 | story | New Session: Project, then On (machine) | Core: Mac, Remote, web; `needs-approval` | 3 |
| 7 | story | Project Settings and the smaller Folder Settings | Mac + web; `needs-approval` | 3 |
| 8 | story | Lane limits per project, counted by the control plane; Project Settings ▸ Work at once; Policy's words | Mac + web; `needs-approval` | 4, 7 |
| 9 | story | Boards: several boards in the Tasks slot, the board filter in Work | Mac + web; `needs-approval` | 7 |
| 10 | story | Work's Project filter | Mac + web; `needs-approval` | 3 |

Slices 1, 2 and 3 can run at the same time. Slices 5, 6 and 7 touch the sidebar, the New
Session page and the settings sheet, which are different areas, so they can run at the
same time after slice 3.

## Decided (Alex can overrule)

- Decided: "folder" stays the word for one directory on one machine, with no new word,
  because #2313 chose the most honest basic words.
- Decided: a project with one folder looks the same as a folder today, because most
  people will have only one folder per project.
- Decided: what travels with Git (`.agents/`, `folder.json`) is the project's, and
  what is only on one machine (disk space, worktrees, ignored files) is the folder's.
  This is because the repository already shares those files between clones.
- Decided: the sidebar and New Session are **Core** (all three clients), because the
  session list and starting a session are Core. Project Settings, limits, boards and Work
  are **Mac + web**, because folder management is Mac + web (#2798).
- Decided: the Remote does not get a Project picker, because #2798 removed folder
  management from it on purpose. It is not a bug.
- Decided: the control plane counts the limits for a project, and a machine without it
  counts its own folder, because only the control plane sees every machine.

## Settled (Alex, 2026-11-02)

- Milestone **0.17 Projects**, core usability, after 0.16 Work and before 0.18 Channels. Slices 1 to 4 (#3274–#3277) are in 0.16, because they change no client and #3265 needs them.

## Open questions

- **"This machine" on the Remote and the web page,** for the machine marks and New
  Session's default. Recommended: the machine you last started a session on in that
  project.
