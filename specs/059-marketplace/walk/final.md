# 059 · Walking what ships (T061–T063), 2026-09-26

On the branch after merging main (`59d9bcc8`, with the security polish S2–S9 and the project
page's Plugins section).

- **Suite:** `swift test`, 2,784 tests. One fails:
  `WorktreeStartTests.aHookThatRefusesStartsNothingAndSaysWhy`. It fails the same way on main
  by itself (a detached worktree of `59d9bcc8`), so it comes in with main, most likely with S3
  ("Daemon git: ignore repo config that would run commands"), which stops the repository hook
  that test relies on. 059 doesn't touch it.
- **Builds:** Agents (Mac) and Remote (generic iOS Simulator) both build. The Linux gate
  (`scripts/build-linux-agentsd.sh --check`) builds both static `agentsd` binaries, so the
  `canImport(CryptoKit)` guards hold.
- **Socket walk on the merged build** (quickstart §3): search, preview, add to You, Shared
  shows the source, add to a project uncommitted, update available after the stand-in moves
  on, update lists the changes and applies them, remove to the scratch Trash, offline says
  unreachable. All passed.
- **On screen:** the project page shows Skills after Workflows, with Plugins after it when a
  project has plugins (merge resolved to keep both). Found: the Skills section didn't show a
  skill added from outside the page (over the socket, or by `npx skills`) until the project was
  opened again. It now also reloads when the app comes back to the front, as Settings ▸ Shared
  does.
