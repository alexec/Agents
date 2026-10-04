# AGENTS.md

## Context routing

- **For the project's purpose and setup:** READ `README.md`.
- **For architecture, terminology and decisions:** CONSULT `docs/`.
- **For a task a skill covers:** USE the skill in `.agents/skills/`.
- **When a task calls for a specialist perspective:** ADOPT a persona from `.agents/personas/`.

## Keeping the web page in step

- **A change to the window's or the Remote's UI** says, in its commit, what the web page (`Web/`) does about it: the same change in the same branch, a parity issue filed, or `web: by design` with the reason. The table of where the page stands is `specs/071-web-remote/walks/parity.md`.

## Verifying a lane's work

- **A lane verifies only what it touched:** the schemes and tests for the paths its branch changes, as `merge-wave.sh plan` lists them. An `App/` change builds `AgentsHost` and `AgentsStore`; a `Remote/` change builds the Remote; a package change runs that package's tests, filtered by `scripts/select-test-suites.sh`. The full AgentsKit suite and every scheme run once, in the merge wave, which also skips any check that already passed at the same tree.
- **Build through `scripts/build-cache.sh`** (`… xcodebuild …`, `… swift test …`): one package and compilation cache in `~/Library/Caches/Agents-build/` for every worktree, so a fresh worktree is not a cold build. Deleting a worktree's own `build/` and `.build` when done is still the rule; the cache stays.
- **Before any xcodebuild, swift build, swift test, scripts/web.sh build or ship.sh, lease the resource "build" with lease_resource (minutes sized to the job, at most 60), and release it with release_resource the moment the command ends.** Never hold it while reading, editing or waiting on the screen.
- **A walk does not hold a place:** a lane that needs one commits, hands the walk on, and ends.
