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
- **`Web/src/protocol/generated.ts` is checked in.** A change to a protocol type runs `scripts/web.sh types` and commits the result; a conflict in it is settled by running that again, never by hand.

## Verifying a lane's work

- **A lane verifies only what it touched:** the schemes and tests for the paths its branch changes, as `merge-wave.sh plan` lists them. An `App/` change builds `AgentsHost` and `AgentsStore`; a `Remote/` change builds the Remote; a package change runs that package's tests, filtered by `scripts/select-test-suites.sh`. The full AgentsKit suite and every scheme run once, in the merge wave, which also skips any check that already passed at the same tree.
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

Alex still decides scope and design (which items, which clients when told otherwise, which approach), restarts of the live app, and anything hard to undo.

## Landing a change

- **Every change has an issue and a pull request.** Work on a branch of your own, push it, open the PR with `gh pr create`, turn on `gh pr merge --auto --squash` at once, and wait for it to land; fix what CI fails. Never push to `main`.
- **Label your session as you go** with set_session_labels: `#<n>` for the issue, `P#<n>` for the PR, and `merged` once it lands.
