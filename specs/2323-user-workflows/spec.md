# Feature Specification: User Workflows

**Feature Branch**: `agents/1923-user-workflows-ready-made`

**Status**: Draft

**Input**: GitHub issue #1923, "User workflows: ready-made workflows live in ~/.agents/workflows, viewed and edited in Settings"

## Why this feature exists

The daemon currently keeps five ready-made workflows inside its program. Each forge
project shows the same workflows. A person has no single place to read or edit them.

This feature puts user workflows in `~/.agents/workflows/<id>.md`. The person can manage
these files in Settings. A project can still have its own workflow with the same ID. The
project file takes priority in that project.

## User scenarios and tests

### Story 1: The person can manage user workflows

The person opens Settings ▸ Workflows. They can see each workflow in `~/.agents/workflows`,
open it, edit it, add a workflow and delete a workflow.

**Acceptance scenarios**

1. Given a valid workflow file in the user workflow folder, when the person opens Settings,
   then the workflow appears in the list.
2. When the person opens a workflow, then the app shows its contents and lets the person
   edit the same file format used for project workflows.
3. When the person adds or deletes a workflow, then the user folder reflects that change.
4. The Mac, Remote and web clients provide the same user workflow controls.

### Story 2: Ready-made workflows become user files

The daemon installs the five current ready-made workflows in the user folder when their
files are absent. The person can then edit or delete them as their own files.

**Acceptance scenarios**

1. Given a ready-made workflow file is absent, when the daemon starts, then it creates the
   file in the user workflow folder.
2. Given the file already exists, when the daemon starts or updates, then it does not change
   that file.
3. Given the person deletes a ready-made workflow, when the daemon starts again, then the
   workflow does not return.

### Story 3: Projects can use user workflows

A forge project can list user workflows that do not have a project file with the same ID.
The workflow starts off in each project. The project keeps its on or off state separately
from the user workflow file.

**Acceptance scenarios**

1. Given a project pushes to GitHub or GitLab, when its workflows are listed, then available
   user workflows appear off by default.
2. Given a project has its own workflow file with the same ID, when workflows are listed,
   then the project file is used and the user workflow is not listed for that ID.
3. Given a user workflow is listed for a project, then the row identifies it as coming from
   the person's workflows.
4. Enabling or disabling a user workflow in one project does not change its state in another
   project or edit the user workflow file.

## Requirements

- **FR-001**: User workflow files MUST use `~/.agents/workflows/<id>.md` and the same format
  as project workflow files.
- **FR-002**: The daemon MUST add each built-in workflow only when its user file is absent.
- **FR-003**: The daemon MUST NOT overwrite an existing user workflow file.
- **FR-004**: Deleting a built-in workflow MUST stop it from returning.
- **FR-005**: Settings MUST list, open, edit, add and delete user workflows.
- **FR-006**: The Mac, Remote and web clients MUST support the same user workflow actions.
- **FR-007**: A project workflow file MUST take priority over a user workflow with the same
  ID.
- **FR-008**: Forge projects MUST list available user workflows as off by default.
- **FR-009**: A project's enabled state for a user workflow MUST be stored separately from
  the user workflow file.
- **FR-010**: Project workflow rows MUST identify a user workflow as coming from the user's
  workflows.
- **FR-011**: User workflow files are user settings. Sync to the control plane and the user's
  machines is covered by related issue #1924.

## Assumptions

- Only projects that push to GitHub or GitLab list user workflows, matching current
  ready-made workflow behavior.
- User workflows are off by default in each project. A person enables each workflow for
  each project.
- Existing project copies remain project workflows. This feature does not migrate them.
- New built-in workflows are added by ID only when that ID is not already present.

## Success criteria

- A person can manage every workflow in the user folder in Settings on all three clients.
- A built-in workflow is installed once and user edits survive daemon restarts and upgrades.
- A project uses its own file when it has a workflow ID that also exists in the user folder.
- A user workflow can be enabled for one project without changing its file or state in
  another project.
