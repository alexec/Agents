# Feature Specification: Projects, the record that folders join

**Feature Branch**: `agents/are-folder-s-software-3`

**Created**: 2026-10-26

**Status**: Part 1 built (this branch). Parts 2–4 are issues of their own.

**Milestone**: 0.11.2 Tech debt

**Input**: Issue #2317, step 4 of #2313 (honest basic terms). Steps 1–3 (#2314 machine provider, #2315 folder, #2316 machine) are merged, so "project" now has one meaning.

## Why this feature exists

**A project is what people work on.** In Jira, GitLab, Azure DevOps and Google Cloud, a project holds the work: its places, its tracker, its review, its CI and its reporting. Agents had no word for this. A folder is one directory on one machine. The same repository cloned on three machines is three folders, and today nothing says that they are one piece of work.

**Team and Enterprise need it.** Usage, cost and policy per project across machines (#733, #998) need a record that spans machines. The tracker, the review and the CI belong to the work, not to one clone.

**This feature adds that record.**

- A project is a record on the control plane, in the organisation.
- A folder joins one project. It names the project's id in its own `.agents/folder.json`.
- When the folder is a Git repository, that line travels with Git. A clone on another machine joins the same project with nothing to set.
- A solo person sees no new step. Each folder is in a project of its own name until the person says otherwise.

**A project is not a repository.** The repository only carries a folder's `.agents/` between clones. A Jira project holds issues and no repository.

## Words

- **Project**: the record that folders join. It has an id, a name, an owner and, later, its tools.
- **Project id**: a short opaque string. Agents makes it (`p-` and 12 random letters and digits). A person never types it.
- **Join**: a folder joins a project when its `.agents/folder.json` names the project's id.
- **Adopt**: the control plane makes a record for a project id that a machine reports and the control plane does not know. The record takes the folder's name.
- **Owner**: the person who made the project, or whose machine reported it first.

## Decisions

| Question (from #2317) | Answer | Who, when |
|---|---|---|
| What a project is | A record on the control plane that folders join, not a folder with extra fields. | Decided in #2317 |
| Folders per project, projects per folder | A folder is in exactly one project. A project has any number of folders. | Decided in #2317 |
| Local first | A project is made for each folder when none is named. | Decided in #2317 |
| 1. Sidebar grouping | **No change.** Folders stay in the one list, as now (#145 has no machine headings). The project's name shows in Folder Settings and on the folder's page. | Decided 2026-10-26, see Clarifications |
| 2. What moves to the project | **The Tasks, Code review and CI slots and what they connect to** (a GitHub repository, a GitLab project, a Jira project). `.agents/mcp.json` stays per folder, and so does the Workspace slot. Part 2. | Decided 2026-10-26 |
| 3. Who may make, rename and delete | **Any member makes and joins. The owner or an admin renames and deletes.** | Decided 2026-10-26 |
| 4. One tracker or several | **One per slot**, as the folder's slots are today. | Decided 2026-10-26 |
| 5. Where the id lives, stale ids | **`"project"` in `.agents/folder.json`.** An unknown id is adopted. A removed id comes back. | Decided 2026-10-26 |

## Clarifications

### Session 2026-10-26 (the #2317 lane, decide and tell; Alex can overrule)

- Q: Sidebar: folders under machines, under projects, or the person chooses?
  → A: **No change.** The sidebar has no machine headings today (one list, #145, this Mac's folders first). For a solo person one folder is one project, so a project heading would double every row. Folder Settings ▸ General says the project, and the folder's page says it under the title when the project's name is not the folder's name. A later issue can add a "group by project" switch when a team asks for it.
- Q: What stays per folder and what moves to the project?
  → A: **Per folder:** `.agents/mcp.json` (any MCP server, and the ones with a local path), the Workspace slot (it is the machine), helper limits, disk space, skills, personas and workflows. **To the project:** the Tasks, Code review and CI slots, the repository, GitLab project or Jira project that each is connected to, and the pull-request and issue pages. A folder in a project with no slot set keeps its own, so nothing breaks on the day Part 2 lands.
- Q: Who may make, rename and delete a project?
  → A: **Any member makes one** (by adding a folder or in Folder Settings) and joins it. **The owner or an admin** renames or deletes it. This follows #1117: what a person makes is theirs, an admin may act for the organisation. On a local control plane the one person is the owner and an admin, so nothing is refused.
- Q: One tracker per project, or several?
  → A: **One per slot**: one Tasks, one Code review, one CI. That is how the folder's slots work today. A project with a Jira project for tasks and a GitHub repository for review sets Tasks to Jira and Code review to GitHub. More than one tracker in one slot waits for a team that needs it.
- Q: Where is the id, and what does a stale or unknown id do?
  → A: **`"project": "<id>"` in `.agents/folder.json`**, beside `helperLimits` and `diskSpace`. It is one more key in a file that already travels with Git, not a new file.
  - **Unknown id** (a clone on another person's control plane, or a project made while offline): the control plane adopts it. It makes the record with that id and the folder's name. The person who owns the machine owns it.
  - **Removed id**: removing a project is refused while a folder that the control plane knows names it. A folder that names a removed id later (an offline machine) brings the record back, with its old name.
  - **Not an id** (empty, too long, wrong letters): the folder is treated as in no project. Folder Settings says "`.agents/folder.json` names a project id that is not valid" and offers the project picker, which writes a good one.
  - **No id**: the machine writes a new id the next time it starts or the folder is added. This writes one line into the folder's `.agents/folder.json`, which a repository then commits so its clones join. v0.x takes breaking changes, so no migration code.
- Q: Does a machine wait for the control plane before it writes an id?
  → A: **No.** The machine makes the id. The control plane learns of it from the machine (`projects/joined`) and adopts it. A machine with no control plane still writes the id, so the folder joins the right project when it gets one.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A folder is in a project, with no new step (Priority: P1)

Sam works alone, on a local control plane. Sam adds a folder as before. Nothing new is asked. Folder Settings ▸ General says **Project: Agents**, the folder's own name.

**Why this priority**: local first. Every later part needs each folder in a project.

**Independent Test**: add a folder on a scratch root. `.agents/folder.json` gets a `project` id. `projects/list` has one project of the folder's name. Folder Settings shows it on the Mac, the Remote and the web page.

**Acceptance Scenarios**:

1. **Given** a folder with no `.agents/folder.json`, **When** Sam adds it, **Then** the file has `"project": "p-…"` and the control plane has a project of the folder's name, owned by Sam.
2. **Given** a folder whose `.agents/folder.json` names a project id that the control plane does not know, **When** Sam adds it, **Then** the control plane adopts the id with the folder's name, and no new id is written.
3. **Given** a folder that was added before this feature, **When** the machine starts, **Then** the folder gets an id, and its project appears.
4. **Given** a machine with no control plane, **When** a folder is added, **Then** the id is still written, and the project appears when the machine joins one.

---

### User Story 2 - Two folders join one project (Priority: P1)

Sam has the same repository cloned on the Mac and on a Linux server. In the server folder's Folder Settings ▸ General, Sam picks **Project: Agents** (the Mac folder's project) from the list. Both folders are now in one project. The old project, with no folder, can be removed.

**Why this priority**: a project that spans machines is the reason for the record.

**Independent Test**: on a scratch root with two folders, pick the first folder's project for the second. Both summaries say the same id. Remove the empty project.

**Acceptance Scenarios**:

1. **Given** two folders in two projects, **When** Sam picks the first folder's project in the second folder's settings, **Then** the second folder's `.agents/folder.json` names the first's id, and both show the same project.
2. **Given** a repository whose `.agents/folder.json` names a project, **When** it is cloned on another machine and added, **Then** the new folder is in the same project with nothing to set.
3. **Given** the project picker, **When** Sam picks **New Project…** and types a name, **Then** a project is made with that name and the folder joins it.

---

### User Story 3 - Rename and remove a project (Priority: P2)

Sam renames the project **Agents** to **Agents app**. Every folder in it, on every machine, shows the new name. Sam removes a project with no folders.

**Acceptance Scenarios**:

1. **Given** a project, **When** its owner renames it, **Then** every client shows the new name within a few seconds (`control/projectsChanged`).
2. **Given** a project that a folder still names, **When** someone removes it, **Then** it is refused: "Move its folders to another project first."
3. **Given** a member who is not the owner and not an admin, **When** they rename or remove the project, **Then** it is refused: "Only the project's owner or an admin can change it."
4. **Given** two projects, **When** someone renames one to the other's name (any case), **Then** it is refused: "There is already a project called …".

---

### User Story 4 - The project's tools (Priority: P2, Part 2)

The Tasks, Code review and CI slots, and the pull-request and issue pages, move from a folder's Connectors page to the project. Each folder of the project gets them. Part 2, #2669 (built).

**As built (#2669):**

- **Control plane.** A project record keeps `slots`: one per slot, either a forge (GitHub or GitLab), a repository and a site, or skipped. `projects/setSlot` sets a slot, or with no value gives it back to each folder. Only the owner or an admin may call it. The `projects/joined` answer is the machine's folders' projects with their slots (`MachineProjects`). After any change to a project, `host/projects` sends the same answer to each machine again.
- **Machine.** The machine keeps the last `MachineProjects` it heard in `<root>/projects.json`. `connectors/setup` fills a slot that the project sets from the project's repository, with `fromProject` and `repository` on the slot and `project` / `projectName` on the set-up. The project's skip is the folder's skip. A slot that the project sets is not skipped by the folder's own skip. `connectors/setup/skip` is refused on such a slot. The sidebar's Issues page (Tasks) and Pull requests or Merge requests page (Code review) get the project's repository as their `repo` / `project` argument. They show even when the folder's own remote is on another forge.
- **Clients.** All three draw the same card under the slots: "Tasks, Code review and CI are the project's (name)… Only its owner or an admin changes them." For the owner or an admin, each slot has **Use for the Whole Project** (the folder's own repository becomes the project's) or **Use Each Folder's Own**. A slot that the project sets says "Set by the project name." and has no Skip and no Change…. The Mac and the Remote use `Shared/UI/ProjectSlotsCard.swift`. The web page uses `ProjectSlots` in `Web/src/views/ConnectorSetup.tsx`.

**Acceptance Scenarios**:

1. **Given** a folder in a project, **When** its owner presses Use for the Whole Project on CI, **Then** every folder of the project reads CI from that repository, and its CI slot says "Set by the project …".
2. **Given** a folder with no remote in a project whose Code review is set, **When** its Connectors page opens, **Then** Code review reads the project's repository, and its Pull requests page shows that repository.
3. **Given** a member who is not the owner and not an admin, **When** they call `projects/setSlot`, **Then** it is refused: "Only the project's owner or an admin can change it."
4. **Given** a project slot, **When** the owner presses Use Each Folder's Own, **Then** each folder's slot is its own again.

### User Story 5 - Reporting per project (Priority: P2, Part 3)

Usage, cost and time are added up per project across machines, beside per person and per machine. Reports get a **Project** dimension. Part 3, its own issue.

### User Story 6 - Projects in the Console (Priority: P3, Part 4)

An admin sees every project in the organisation, its folders on each machine and its owner, in Console ▸ Projects on the web page. The Add Folder sheet on each client gets a Project picker. Part 4, its own issue.

### Edge Cases

- A folder whose `.agents` is a link to another folder (`ownFolders` false): no id is written, and the folder is in no project. Folder Settings says why.
- `.agents/folder.json` that is not a JSON object: no id is written. The folder is in no project, and Folder Settings shows the file's own error.
- `.agents/folder.json` with a change waiting for Keep or Undo (a guarded file): the machine does not write the id until the change is settled. It tries again when the change is kept or undone.
- Two machines adopt the same unknown id at once: the control plane's etag check keeps one record. Both folders join it.
- A folder that is archived keeps its id. A folder that is deleted from the list leaves its file as it is.
- A machine that is offline: its folders keep their id. The project is not removed while the control plane still remembers a folder in it.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The control plane MUST keep projects as records under `v1/projects/<id>.json`: id, name, owner, made at, rev, and a removed mark. The record keeps fields that it does not know (`Extra`), as groups do.
- **FR-002**: `projects/list` MUST return the organisation's projects that are not removed, with each project's folders as the machines last reported them (machine id and folder URL). Any person may call it.
- **FR-003**: `projects/set` MUST make a project (no id) or rename one (id). Any person may make one; only the owner or an admin may rename one. Names are 1–80 characters after trimming and are unique without regard to case.
- **FR-004**: `projects/remove` MUST remove a project. Only the owner or an admin may. It MUST be refused while a folder that a machine last reported names it.
- **FR-005**: The control plane MUST tell every client `control/projectsChanged` when a project is made, renamed, removed or adopted, and every copy (`announce`).
- **FR-006**: A machine MUST send `projects/joined` to its control plane: each folder's URL, name and project id. It sends it when it connects and when a folder's project changes, is added or is deleted.
- **FR-007**: On `projects/joined` the control plane MUST adopt each unknown or removed id: it makes the record (or takes away the removed mark), with the folder's name (made unique by " 2", " 3", …), owned by the machine's owner. It MUST remember the machine's folders for FR-002 and FR-004.
- **FR-008**: A machine MUST write a new project id into `.agents/folder.json` (`"project"`) for each folder that has none, when the folder is added and when the machine starts. It MUST NOT write when the file is not an object, `.agents` is a link, or the file has a guarded change waiting.
- **FR-009**: `FolderSummary` MUST carry the folder's project id (`project`) as `.agents/folder.json` says it, and `projectProblem` when the file names a value that is not a valid id.
- **FR-010**: `folders/setProject` (on the machine) MUST write a project id into a folder's `.agents/folder.json`, through the same guard as helper limits, and send `projects/joined`.
- **FR-011**: Folder Settings ▸ General on the Mac, the folder's settings on the Remote, and the folder's settings on the web page MUST show a **Project** picker: the projects of the organisation, **New Project…**, and, for the owner or an admin, **Rename Project…**. Picking one calls `folders/setProject`; New Project calls `projects/set` and then `folders/setProject`.
- **FR-012**: A project id is `p-` and 12 letters and digits for the ones Agents makes. Any string of 1–64 letters, digits, `-` and `_` is accepted as an id, so a hand-written one works.
- **FR-013**: Nothing about a project goes to the store in clear text that is a secret. A project holds names and ids only.

### Key Entities

- **Project** (control plane): `id`, `name`, `owner` (person id), `madeAt`, `rev`, `removed`, `removedAt`.
- **Project folders** (control plane, in memory and in `v1/projects/joined/<machine>.json`): for each machine, the list it last sent: folder URL, folder name, project id.
- **Folder config** (machine, `.agents/folder.json`): gains `"project": "<id>"`.

## Success Criteria *(mandatory)*

- **SC-001**: A solo person who adds a folder sees no new question, sheet or step.
- **SC-002**: A clone of a repository with a project id, added on a second machine, is in the same project with zero clicks.
- **SC-003**: A rename shows on every client within 5 seconds.
- **SC-004**: The Project picker is on all three clients, and each walk shows it working on a scratch root.

## Parts

| Part | What | Issue |
|---|---|---|
| 1 | The record, adoption, `.agents/folder.json`'s `project`, `folders/setProject`, the Project picker in folder settings on all three clients, the docs. | #2317 (this branch) |
| 2 | The Tasks, Code review and CI slots and the pull-request and issue pages move to the project. | #2669 (built) |
| 3 | A Project dimension in Reports, Usage and Time. | #2670 |
| 4 | Console ▸ Projects, and a Project picker in the Add Folder sheet on all three clients. | #2671 |

## Docs

- `docs/explanation/direction.md`: the tenancy tree already has the project. Say how a folder joins.
- `docs/explanation/folders-machines-worktrees.md`: a section "A folder is in a project".
- `docs/how-to/add-a-folder.md`: a line on the project.
- `docs/reference/`: the `project` key of `.agents/folder.json`, where the file's keys are listed.

## Assumptions

- Every machine that runs agents has a control plane, local or remote, or will join one. A machine with none still writes the id.
- The folder's name is the last part of its path, as the sidebar shows it.
