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

## Verifying a lane's work

- **A lane verifies only what it touched:** the schemes and tests for the paths its branch changes, as `merge-wave.sh plan` lists them. An `App/` change builds `AgentsHost` and `AgentsStore`; a `Remote/` change builds the Remote; a package change runs that package's tests, filtered by `scripts/select-test-suites.sh`. The full AgentsKit suite and every scheme run once, in the merge wave, which also skips any check that already passed at the same tree.
- **Build through `scripts/build-cache.sh`** (`… xcodebuild …`, `… swift test …`): one package and compilation cache in `~/Library/Caches/Agents-build/` for every worktree, so a fresh worktree is not a cold build. Deleting a worktree's own `build/` and `.build` when done is still the rule; the cache stays.
- **Before any xcodebuild, swift build, swift test, scripts/web.sh build or ship.sh, lease the resource "build" with lease_resource (minutes sized to the job, at most 60), and release it with release_resource the moment the command ends.** Never hold it while reading, editing or waiting on the screen.
- **A walk does not hold a place:** a lane that needs one commits, hands the walk on, and ends.
