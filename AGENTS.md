# AGENTS.md

## Context routing

- **For the project's purpose and setup:** READ `README.md`.
- **For architecture, terminology and decisions:** CONSULT `docs/`.
- **For a task a skill covers:** USE the skill in `.agents/skills/`.
- **When a task calls for a specialist perspective:** ADOPT a persona from `.agents/personas/`.

## Durable data

- Store data in the project itself when possible.
- When important long-term data cannot safely live in the project, store it on disk in `~/.agents` when safe. Do not rely on an agent's memory for data that can safely be stored there.

## Keeping the three clients in step

- **Three clients draw the same product:** the Mac window (`App/`), the Remote on iPhone and iPad (`Remote/`), and the web page (`Web/`). `Shared/UI` is drawn by both the window and the Remote.
- **A change to any client's UI** (`App/Sources`, `Remote/Sources`, `Shared/UI` or `Web/src`) says, in its commit, what **each of the other two** does about it, one line each:
  - the same change in this branch: `remote: same`;
  - a parity issue filed: `web: #NNN`;
  - left out on purpose: `mac: by design (no swipe on Mac)`.
- **For example,** a Mac sidebar change ends with `remote: #226` and `web: same`; a web-only fix ends with `mac: same, remote: same` when both already do it. A change to docs only says `mac: docs only, remote: docs only, web: docs only`.
- **The table of where each client stands** is `specs/071-web-remote/walks/parity.md` (Mac / Remote / web, a row per screen and feature). A parity line that changes a row updates it in the same branch.

## Web/dist and generated.ts

- **`Web/dist` is not checked in** (#473); it is in `.gitignore`. Agents Host's build makes it with `scripts/web.sh dist` (the Node in `Web/.node-version`; without it, an empty one and a warning). Run `scripts/web.sh build`, under the "build" lease, to see a web change without a Mac build.
- **The wire's types come from `Packages/Wire` (#1135).** A change to a protocol type changes `Packages/Wire/daemon.schema.json` (or a method in its `*.openrpc.json`) first, runs `scripts/wire.sh gen`, and commits what it makes (`Web/src/protocol/generated.ts`, `Go/wire/*_gen.go`); `WireSchemaTests` then says what to change in Swift by hand. A conflict in a generated file is settled by running that again, never by hand.

## Verifying a lane's work

- **A lane verifies only what it touched:** the schemes and tests for the paths its branch changes, as `merge-wave.sh plan` lists them. An `App/` change builds `AgentsHost` and `AgentsStore`; a `Remote/` change builds the Remote; a package change runs that package's tests, filtered by `scripts/select-test-suites.sh`. The full AgentsKit suite and every scheme run once, in the merge wave, which also skips any check that already passed at the same tree.
- **Lint with `scripts/lint.sh`** (#1224): shellcheck, `zsh -n` and our text checks fail CI's `lint` job; golangci-lint, govulncheck, ruff, Biome and SwiftLint only report, and say which findings are in your files (`LINT_BASE=origin/main`). On the Mac each runs in a container: nothing to install. `scripts/lint.sh --fix` runs the fix modes.
- **Build through `scripts/build-cache.sh`** (`… xcodebuild …`, `… swift test …`): one package and compilation cache in `~/Library/Caches/Agents-build/` for every worktree, so a fresh worktree is not a cold build. Deleting a worktree's own `build/` and `.build` when done is still the rule; the cache stays. Its `swift test` sets `AGENTS_QUARANTINE=1`, so tests marked `.flakyUnderLoad` skip as on CI; `AGENTS_QUARANTINE=0` runs them.
- **Before any xcodebuild, swift build, swift test, scripts/web.sh build or ship.sh, lease the resource "build" with lease_resource (minutes sized to the job, at most 60), and release it with release_resource the moment the command ends.** Never hold it while reading, editing or waiting on the screen.
- **A walk does not hold a place:** a lane that needs one commits, hands the walk on, and ends.

## Questions that already have an answer

Alex answered these the same way every time (#601), so do them without asking and say so in your reply:

- **Tests that fail on main too, or timing tests that fail under load:** accept them and go on. Mark one that keeps failing `.flakyUnderLoad` and file an issue; rerun a CI check that failed for something unrelated to your change.
- **Main itself broken (a build, the Linux host):** fix main first, by its own PR, then carry on.
- **Alex's uncommitted edits in the main checkout:** leave them alone. When a pull needs a clean tree, carry them across it: `git stash push -u -m <your-tag>`, pull, `git stash apply` that entry, then drop it. The stash is shared by every worktree, so never use a bare `git stash pop`. Never commit or discard Alex's edits.
- **Your own scratch worktrees and /tmp folders:** discard them when your work is committed.
- **A PR that goes stale in conflict:** rebase it and let auto-merge take it once it is green.
- **A UI change:** do all three clients unless Alex says otherwise.
- **Something to look at on a device or the screen:** look yourself first (`devicectl` screenshots, run-app on a scratch root). Ask Alex only for what needs Alex's hands, such as unlocking a phone.
- **A report with nothing to choose** (stuck PRs, nothing found): say it and end. Do not ask what to do about it.
- **"I'm just investigating", "what about…":** give the findings and the options in your reply and stop. Alex will say what to build.

**Decide and tell (#1083).** When one option is the one you would mark recommended and it is easy to undo, take it, also for scope and design (which items, which clients, which approach, look and names). Write `Decided: <X>, because <Y>. Alex can overrule.` in the issue (in the PR body when there is no issue), add the `decided` label to the issue, say it in your reply, and carry on. A reversed decision costs one PR at most (v0.x takes breaking changes).

Alex still decides, by a form: anything hard to undo (deleting data, rewriting history, anything published outside the repo), spending money or making an outside account, restarts of the live app and installs on Alex's devices, and a choice with no option clearly the best.

## Work by milestone (#1340)

- **Work goes by milestone.** The Scrum Master takes issues from the earliest open milestone first, bugs before features. An issue with no milestone is the backlog, except `polish` and `competitor` issues, which have a lane of their own.
- **A filed issue gets a milestone** only when it serves that milestone's goal (#1340). Bugs are the exception: they always go in the open milestone.
- **Bugs go in the open milestone.** A bug is filed into the open milestone, whatever its theme. When a release ships, the release skill moves the milestone's open bugs to the next milestone before it closes the milestone.
- **Polish and competitor gaps have no milestone.** Issues labelled `polish` or `competitor` stay out of milestones. The exception is a competitor gap that serves a milestone's goal; it keeps that milestone. One standing lane works them alongside the milestone lanes, highest RICE first, under the same area and open-PR limits. They are for no milestone, so they can merge before a release ships (#1570).
- **The open milestone and the next one are workable;** the next one only in areas the open one does not hold. Later milestones' issues keep `parked`; take it off when their milestone becomes the next one.
- **A milestone is done when its release has shipped** (the GitHub release and both TestFlight builds), not when GitHub closes it. No change for the next milestone merges to `main` before that (Alex, 2026-10-18). The release skill closes the milestone.

## Landing a change

- **Every change has an issue and a pull request.** Work on a branch of your own, in a worktree you moved into with move_worktree (never one made by hand with `git worktree add`, which the app never sees: #615), push it, open the PR with `gh pr create`, turn on `gh pr merge --auto --squash` at once, and wait for it to land; fix what CI fails. Never push to `main`.
- **A change to an integration's state updates its row (#1283).** A PR that adds, removes, walks, tests on a real account, breaks or fixes a third-party integration updates its row in `docs/reference/integrations.md` in the same branch, as a parity line does for `parity.md`. The weekly runtime check writes the runtime rows; edit the others by hand. An issue about an integration gets the `integration` label.
- **One lane per feature area at a time (#873).** `.agents/areas` maps paths to areas (`sidebar`, `events`, `agent-tools`, `brief`, `workspaces`); the `areas` CI step labels each PR `area:<name>` from its files and warns when another open PR holds the same area. An issue you file gets its `area:<name>` label when it has one. Do not start an issue whose area an open PR or a running lane holds: take the next one. Do the parts of one spec, or a change and its per-client follow-ups, in one lane or one after another, and land a change across many files (a rename, a removal) when no other lane is active. `scripts/replay-conflicts.py` counts the conflicts PRs met.
- **An issue is taken** when a session is labelled `#<n>`, an open PR fixes it, or the session that filed it is not archived yet (it may be fixing it). Take the next one.
- **Conflicting PRs land one at a time.** When more than one open PR is in conflict, one landing lane rebases and lands them in turn, and the others' auto-merge is off until it is theirs.
- **Label your session as you go** with set_session_labels: `#<n>` for the issue, `P#<n>` for the PR, and `merged` once it lands.
