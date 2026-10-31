# Tasks: Projects, the record that folders join

**Input**: [spec.md](spec.md), [plan.md](plan.md). Part 1 (#2317). Parts 2–4: #2669, #2670, #2671.

## Phase 1: Wire

- [x] T001 Add Project, ProjectList, ProjectSet, ProjectRequest, ProjectsChanged, ProjectFolder, ProjectsJoined, SetFolderProjectRequest and FolderSummary.project / projectProblem to `Packages/Wire/daemon.schema.json`
- [x] T002 Add projects/list, projects/set, projects/remove, projects/joined and control/projectsChanged to `Packages/Wire/control.openrpc.json`; folders/setProject to `daemon.openrpc.json`
- [x] T003 Run `scripts/wire.sh gen` and commit what it writes

## Phase 2: Control plane (US1, US2, US3)

- [x] T004 [US1] `Go/internal/controlplane/records/projects.go`: the record, `loadProjects`, `Projects`, `Project`, `ChangeProject` (sees removed ones)
- [x] T005 [US1] `Go/internal/controlplane/projects.go`: `projects/joined` (keep the machine's list, adopt unknown and removed ids), `projects/list`
- [x] T006 [US3] `projects/set` (make, rename; owner or admin), `projects/remove` (refused while a folder names it), `control/projectsChanged`, announce to copies
- [x] T007 Dispatch in `methods.go` (own, writes, switch, machine switch), `mesh.go`, the every-method owner test
- [x] T008 Tests: `projects_test.go`

## Phase 3: Machine (US1, US2)

- [x] T009 [US1] `Go/internal/agentsd/folderproject.go`: write an id for a folder with none at add and at start; `FolderSummary.project` from the file
- [x] T010 [US2] `folders/setProject`; send `projects/joined` on connect and on change
- [x] T011 Tests: `folderproject_test.go`

## Phase 4: Clients (US1, US2, US3)

- [x] T012 AgentsKit: `Project`, `ProjectList`, `FolderSummary.project`, the DaemonAPI calls; `WireSchemaTests` rows
- [x] T013 Shared UI: `ProjectPicker` (projects, New Project…, Rename Project…)
- [x] T014 Mac: Folder Settings ▸ General ▸ Project
- [x] T015 Remote: folder menu ▸ Project…
- [x] T016 Web: `model/projects.ts`, `views/ProjectPicker.tsx`, folder menu ▸ Project…; Vitest

## Phase 5: Docs and walk

- [x] T017 Docs in the spec's Docs section; parity rows
- [x] T018 Walk: run-app scratch root on the Mac and the web page; the Remote built (its folder menu is a context menu, which the walk socket cannot open)
