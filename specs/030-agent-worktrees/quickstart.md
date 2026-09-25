# Quickstart: Checking That 030 Works

Everything here runs in the worktree `/tmp/w-030`, against scratch repositories under
`/tmp/wt-030`. Nothing touches the shared checkout, the real daemon, or any real project's
worktrees.

## 1. Package tests

```sh
cd /tmp/w-030/Packages/AgentsKit && swift test
```

Expected to pass, including new tests that cover:
- **Naming (R3)**:
  - "Fix the login redirect on Safari" gives `fix-login-redirect-safari`.
  - A prompt of only symbols, or only an attachment, gives `agent-MMdd-HHmm`.
  - Output is never over 32 characters and never ends in `-`.
  - A clash on the folder or the branch gives `-2`, then `-3`.
- **Concurrency (SC-003)**: two `new` starts from the same prompt, overlapping, each with a fake
  runtime whose handshake waits. Expect two worktrees with different names and branches.
- **Making one (FR-011)**:
  - Use a real `git init` repo in a temp folder with one commit.
  - After a `new` start, `git worktree list` has the worktree, and the branch is `agents/<name>`.
  - The fake runtime was launched with process and session `cwd` both equal to the worktree.
  - `.git/info/exclude` contains `/.agents/worktrees/`, and `git status --porcelain` in the
    project folder is empty (SC-006).
- **Subfolder project**: the project is `repo/app`. After a `new` start, the agent's `cwd` is
  `<worktree>/app`.
- **Failures (FR-013)**:
  - A repo with no commits gives `canMakeNew: false` and a refused start.
  - A `post-checkout` hook that exits 1 gives `worktreeFailed`, with no agent saved and no runtime
    left running.
- **Filing (FR-014)**:
  - An agent with a worktree is counted in its project's `allProjects` summary.
  - It isn't a project of its own.
  - It counts toward the 028 helper limit.
  - `AgentsModel.agents(in:)` returns it for the project folder.
- **Old records**: an agent JSON without `worktree` decodes, with `projectFolder == cwd`.
- **Resume (FR-017)**:
  - Delete the worktree folder and ask to resume. Expect `worktreeMissing` and no launch.
  - The fake launcher is never called with the project folder.
- **Listing (US2)**:
  - A worktree made with plain `git worktree add` is listed with `madeByApp: false`.
  - A `prunable` one is listed with `exists: false`.
  - A start into it with `existing` works.
  - A start with a URL from another repository gives `notAWorktree`.
- **Removal (US3)**:
  - Archiving leaves the worktree and branch.
  - `worktrees/remove` is refused while an agent (not archived) is in it, and refused for one
    not made by the app.
  - It asks for confirmation when there's an uncommitted file or an unmerged commit.
  - A clean, merged worktree is removed along with its branch.
- **`start_agent` (US4)**:
  - `worktree: "new"` gives a helper in a new worktree, filed under the caller's project.
  - An unknown name is refused with the daemon's message.

Assert properties directly: never edit source to prove a test (see memory).

## 2. Builds

Both schemes, one after the other, with plugin validation skipped (see memory: xcodebuild needs
plugin-validation skipped):

```sh
cd /tmp/w-030 && xcodegen generate
xcodebuild -scheme Agents -configuration Debug -skipPackagePluginValidation -skipMacroValidation build
xcodebuild -scheme Remote -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -skipMacroValidation build
```

## 3. Each runtime, for real (SC-002)

This runs before the UI work, because it settles R2. On a scratch daemon, with a scratch repo at
`/tmp/wt-030/repo` that has one commit, do the following for each of Claude, Grok, Copilot and
Cursor:
1. Start with `worktree: new` over `daemon.sock` and the prompt *"Create a file called
   proof-<runtime>.txt containing your working directory."*
2. Expect:
   - The file is in `/tmp/wt-030/repo/.agents/worktrees/<name>/`.
   - Its contents are that path.
   - The project folder has no new file, and `git status` in the project folder is clean.

Drive `agentsd` by hand as memory says: never `env -i`, `cwd` is a `file://` URL, and stagger
the npx starts.

## 4. End to end in the app (run-app skill)

Launch the app built from `/tmp/w-030` on a scratch root, with `/tmp/wt-030/repo` as a project.

1. **Chooser**:
   - The start bar shows **Worktree: Project folder** next to the folder.
   - Choose **New worktree**, send "Add a line to README", and expect to be taken into the agent.
   - Its row shows the worktree badge.
   - The files pane shows the worktree.
   - The project folder's README is unchanged.
   - Screenshot the start bar with the chooser open, and the row.
2. **Resets**: after the start, the chooser reads **Project folder** again.
3. **Existing**:
   - Open the chooser, where the first agent's worktree is listed with "1 agent working".
   - Choose it and send "Read README".
   - Expect a second agent in the same worktree, filed under the same project.
4. **Not a repository**: add `/tmp/wt-030/plain` (no git) as a project. The start bar has no
   Worktree choice.
5. **Cleanup**:
   - Archive both agents. The project page's **Worktrees** section still lists the worktree.
   - Press **Remove…** and expect a confirmation naming the uncommitted README change.
   - Confirm, and the worktree and branch are gone.
   - Screenshot the section before and after.
6. **Restart**:
   - With an agent in a worktree, quit and relaunch the scratch app and daemon.
   - The agent is still under its project and resumes in its worktree.

Stop the scratch app when done. Never kill `agentsd` by name: take the pid from the scratch root's
`daemon.lock`.

## 5. Phone

The phone can't be tapped on this Mac. Boot the Remote app against the scratch root, and
screenshot a project with a worktree agent to show the badge and that it isn't a project of its
own. The walk is Alex's.
