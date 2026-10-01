# Quickstart: Validate session labels

This is an implementation validation guide. It does not prescribe the implementation
details; see [data-model.md](data-model.md) and [contracts/labels-tools.md](contracts/labels-tools.md).

## Prerequisites

- macOS with Xcode and the repository's Swift 6 toolchain.
- A scratch project folder and disposable daemon root for manual flows.
- At least two connected app views (Mac plus Remote) to check change propagation.
- A test project on a Linux server for the server-hosted scenario.

## Automated checks

Run the package suite and build both app schemes from the repository root:

```sh
swift test --package-path Packages/AgentsKit
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
xcodebuild -scheme Remote -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation build
```

Expected: package tests pass; both schemes build without warnings promoted to errors.
The added tests should cover the cases below at their model/tool/daemon boundaries.

## Manual scenarios

1. Start a new session with `perf`; verify the first card and chat header show it.
2. Add another label from the session menu while its turn runs; verify Mac and Remote
   update without reopening the session. Remove it from the header and verify both update.
3. Add one label as the person and one through `finish_turn`. Verify filled versus outlined
   styles and accessible owner wording on the Mac row, Remote card, and chat header.
4. Ask the agent to remove the person's label and to add the same value as its own. Verify
   each call explains the ownership conflict and neither changes the person's label.
5. Attempt a sixth distinct label, a whitespace-only label, and a 25-character label.
   Verify each operation is refused atomically and the existing labels remain.
6. Use `label:perf` in session search, then add ordinary text. Verify label-only and combined
   filtering return exactly the expected sessions, including case-insensitive matches.
7. Start helpers directly and through a workflow with labels; verify all produced sessions
   carry agent-owned labels. Confirm `list_sessions` and `list_my_agents` include labels and
   owners.
8. Archive and restore a labeled session; verify its labels and owner classes survive.
   Start a separate chat and have it read that session's history; verify the new chat
   begins without those labels.
9. Repeat on an isolated server project from the Mac; verify its labels do not appear in
   a Mac project's suggestions and that server label changes appear in the Mac app.

## Acceptance evidence

- All four independent story checks in `spec.md` pass.
- A 200-session label filter completes in under 1 second (SC-005).
- Label changes reach connected devices in under 5 seconds (SC-002).
- No session exceeds five labels or displays more than two on a Remote card; the remainder
  is summarized as `+N`.
