---
name: dead-code-review
description: Review changed Swift, Go and web code for unreachable code on each release with Periphery, deadcode and Knip, record false positives, and remove only code proven dead. Use when the Dead code review workflow runs in a release (#2161), or when Alex asks for a dead-code review.
---

Paused until 1.0 (#3215).

# Dead-code review

This is the method of the Dead-code review workflow
(`.agents/workflows/dead-code-review.md`). The workflow says what the method is for and
starts it. A person or agent can also follow it by hand. Where it says that nobody is at
the keyboard, that is true only of a workflow run.

## Rules for the whole run

- Work only in the review worktree and helper worktrees. Do not change the shared checkout.
- Never push to `main`, merge, ship, restart the app or call the live app's `daemon.sock`.
- Do not delete code on the review branch. Each language/client deletion is a separate
  helper branch and pull request. A helper must explain why the finding cannot be reached
  through reflection, generated code, a runtime entry point, a test hook or an external
  consumer. Leave uncertain findings in the report.
- Before any Xcode or Swift build, lease `build`; release it as soon as the command ends.
  Keep the lease only while the build runs. Periphery uses the Mac's Xcode index and
  cannot run in a Linux container.
- Periphery is pinned at 3.8.0. Download its release archive to a temporary folder and
  run that binary; do not install it. Verify its SHA-256 against the recorded value in
  `baseline.md` before use.
  Scan `AgentsHost`, `AgentsStore` (the Mac window: `App/Sources`), `Remote` and every
  `Packages/*` Swift package. Run `xcodegen generate` first (`Agents.xcodeproj` is not
  checked in, and a copy older than the merge of `main` misses new files). Build the
  three schemes one at a time with plain `xcodebuild`
  (`-derivedDataPath build/DD-periphery`, the build cache's package checkout through
  `-clonedSourcePackagesDirPath`, `COMPILER_INDEX_STORE_ENABLE=YES`), not through
  `scripts/build-cache.sh`: its prefix mapping writes `/^worktree` paths into the index,
  and Periphery then finds nothing. Run one scan over all three schemes with
  `--skip-build --index-store-path build/DD-periphery/Index.noindex/DataStore`. For a
  package, `swift build --build-tests --build-system native -Xswiftc -index-store-path
  -Xswiftc .build/periphery-index` (Swift 6.4's default build system writes no index),
  then `periphery scan --skip-build --index-store-path .build/periphery-index
  --retain-public`. The Xcode index can still be partial: a Swift finding counts only
  when its name appears nowhere else in tracked Swift files. Record the exact command
  and any target the scan could not index.
- Run `deadcode` from `golang.org/x/tools/cmd/deadcode@v0.49.0` inside the same pinned Go
  container used by `scripts/lint.sh`; scan `./...` from `Go/`. Scan again with
  `GOOS=darwin GOARCH=arm64` (install `deadcode` for linux first, then run it with those
  set), or every function with only `_darwin.go` callers reads as dead.
  If the container is killed for memory (exit 137; the VM has about 4 GB), run the same
  `deadcode` on the Mac with the Go of `go.mod` downloaded from go.dev to a temporary
  folder (verify its SHA-256 against go.dev's list; do not install it), with `GOOS=linux`
  and then `GOOS=darwin` set, and record that in the report.
- Run Knip 6.42.1 from the pinned `node:$NODE` container used by `scripts/lint.sh`, with
  `KNIP_DISABLE_RAW_TRANSFER=1` (needed for container memory limits) and the npm cache
  under `~/Library/Caches/Agents-build/npm`; run it from `Web/`. Keep the
  explicit build entry points in `Web/knip.json`. Use `--include files,exports
  --include-entry-exports`; dependencies are outside this review's scope.
- Nobody is at the keyboard during a workflow run. Do not ask questions. Record any
  choice that needs Alex as `needs a decision`, with the options and evidence.

## 1. Set up and scope

1. Move to `.agents/worktrees/reviews-dead-code` through `move_worktree`, on the local
   branch `agents/reviews-dead-code`. If the branch exists, call `move_worktree` with
   worktree `agents/reviews-dead-code`: the app moves you into its worktree, or makes one
   on it. Never run `git worktree add` (#3174). Otherwise, ask the app for a new worktree
   named `reviews-dead-code`. End the turn after the move. Merge `main` in that worktree.
2. Read every file in `.agents/reviews/dead-code/`. The newest run file has
   `reviewed-through:` with the last reviewed `main` commit. If no run file exists,
   start at the last release tag.
3. Review `git diff <previous reviewed-through>..main` for Swift, Go and web code. On the
   first run, use `git diff <last release tag>..main`. Also search current source for
   compatibility code using `before 0NN`, `older build`, `legacy` and `no longer`.
   Review only matches that are still in source; ignore docs, release notes, tests that
   describe old behavior and generated files. v0.x has no migration code.
4. Read `.agents/reviews/dead-code/baseline.md` before interpreting scanner output.
   Keep a finding only if it is new or the code or reachability has changed since the
   recorded baseline.

## 2. Review

Run all three analyzers and the compatibility search in step 1.3. Do not treat a tool
result as proof by itself. Check call sites, target membership, protocol and serialization
use, App Intents, Objective-C selectors, reflection, test-only hooks and entry points.
Generated code is excluded unless a handwritten reference is dead.

For every false positive, add a durable baseline entry with the exact declaration or
path, the analyzer, and the reason it is live. Use Periphery `retain_*` configuration or
`// periphery:ignore` only for a declaration with a documented reason. Use Knip's
`ignore` only for a path with a documented reason. Keep the Go baseline in
`.agents/reviews/dead-code/baseline.md`; do not hide Go findings with broad exclusions.
Include the baseline update in the report branch.

For every likely-dead finding, give severity (critical, high, medium or low), the exact
`file:line` or declaration, the analyzer output, the reachability check, and the proposed
removal. Mark a finding `sure` only when the full target set was indexed and no runtime,
generated, reflective or external entry point can use it. Otherwise mark it `uncertain`
or `needs a decision`.

## 3. Write findings and baseline

Write `.agents/reviews/dead-code/<YYYY-MM-DD>.md` with front matter:

```yaml
reviewed-through: <git rev-parse main>
base: <last release tag>
previous: <previous reviewed-through or none>
```

Record the commands, tool versions, failed or incomplete scans, compatibility search
terms, findings and baseline changes. A run with no findings still records what it read
and confirms that all targets were scanned. Append each new false positive to
`.agents/reviews/dead-code/baseline.md` with its reason. Commit the report and baseline
on `agents/reviews-dead-code`.

## 4. Remove code that is surely dead

Group `sure` findings by client or language: Mac/Host, Remote, each independent Swift
package, Go and Web. Start no more than one helper for a group at a time, and stay within
the folder's session limits. Give each helper a new worktree off `main` and one group.
The helper removes only that group's code, updates any necessary tests, runs the unit
tests for touched paths, and opens one pull request with `Fixes #<finding issue>`.
The PR explains the reachability proof and includes the client parity lines if a deletion
changes what a client draws. Do not combine groups into one PR. If no helper slot is
available, record the finding for the next run. Leave low-confidence findings in the
report; do not create a removal branch for them.

## 5. Finish

Wait for each helper with `wait_for_event` naming its session. Read the helper's last
message and check its pull request and checks. Record the PR and status in the report.
Archive helpers after their PR merges or is abandoned. Commit the final report changes on
`agents/reviews-dead-code`. End with a line per finding and the path to the report.
