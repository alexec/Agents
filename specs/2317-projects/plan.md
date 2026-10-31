# Implementation Plan: Projects, the record that folders join

**Branch**: `agents/are-folder-s-software-3` | **Date**: 2026-10-26 | **Spec**: [spec.md](spec.md)

**Input**: `specs/2317-projects/spec.md` (#2317). This plan covers Part 1. Parts 2–4 are #2669, #2670 and #2671.

## Summary

The control plane keeps a project record per project (`v1/projects/<id>.json`), as it keeps groups. A machine writes a project id into each folder's `.agents/folder.json` (`"project"`) when the folder has none, and sends its folders and their ids to the control plane (`projects/joined`). The control plane adopts each id it does not know, with the folder's name. Clients list projects (`projects/list`), make and rename them (`projects/set`), remove them (`projects/remove`), and put a folder in one (`folders/setProject`, on the machine). Each client's folder settings gets a Project picker.

## Technical Context

**Language/Version**: Go (`agents-control`, `agentsd`), Swift 6 (Mac window, Remote, `Shared/UI`, AgentsKit), TypeScript (web page).

**Primary Dependencies**: none new. Ids from `crypto/rand`.

**Storage**: control plane: `v1/projects/<id>.json` (records, cached and loaded every 15 s with the others) and `v1/projectFolders/<machine>.json` (what each machine last sent). Machine: one key in `.agents/folder.json`.

**Testing**:

- `Go/scripts/go.sh test ./internal/controlplane/... ./internal/agentsd/...`: make, rename, remove, refusals (owner, admin, member), adoption (unknown and removed ids, name clashes), `projects/joined` bounds; the machine writes an id at add and at start, leaves a bad file and a linked `.agents` alone, `folders/setProject`.
- `swift test` filtered by `scripts/select-test-suites.sh`: `WireSchemaTests`, the project words.
- Vitest: `Web/test/projects.test.mjs`.
- Walk: `run-app` on a scratch root, the Mac window, the web page (headless Chrome), and the Remote on the walk simulator.

**Constraints**: local first (SC-001). Nothing secret in a project. Bounded: at most 1000 folders per `projects/joined`, names at most 80 characters, ids at most 64.

## Constitution Check

| Principle | How |
|---|---|
| I. Spec-led | Spec, plan and tasks come first, in this branch. |
| II. Capability-driven | New capability `projects/1`; methods carry it. |
| III. Scoped access | Owner or admin for rename and remove (#1117 model). A client that is not the owner sees the picker without Rename. |
| IV. Inspectable | The id is in a plain file in the folder. Every refusal says why. |
| V. Docs travel | The docs in the spec's Docs section change in this branch. |

## Project Structure

```text
Packages/Wire/daemon.schema.json        Project, ProjectList, ProjectSet, ProjectRequest, ProjectsChanged,
                                        ProjectFolder, ProjectsJoined, SetFolderProjectRequest; FolderSummary.project
Packages/Wire/control.openrpc.json      projects/list, projects/set, projects/remove, projects/joined, control/projectsChanged
Packages/Wire/daemon.openrpc.json       folders/setProject
Go/internal/controlplane/records/projects.go (new)   the record, load, change
Go/internal/controlplane/projects.go (new)           methods, adoption, joined folders
Go/internal/controlplane/methods.go, mesh.go         dispatch, writes, copies
Go/internal/agentsd/folderproject.go (new)           id in folder.json, folders/setProject, projects/joined
Packages/AgentsKit/.../Model/Project.swift (new)      Project, ProjectList, words
Packages/AgentsKit/.../Daemon/DaemonAPI+Projects.swift (new)
Shared/UI/ProjectPicker.swift (new)                  the picker, used by the Mac and the Remote
App/Sources/Folders/FolderSettingsSheet.swift        General: Project
Remote/Sources/Sidebar/RemoteSidebar.swift            folder menu: Project…
Web/src/model/projects.ts, Web/src/views/ProjectPicker.tsx (new), Sidebar.tsx folder menu: Project…
docs/                                                the pages in the spec's Docs section
```

## Complexity Tracking

None.
