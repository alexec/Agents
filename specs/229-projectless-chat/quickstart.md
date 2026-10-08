# Quickstart: prove the chat project (#229)

Never point any of this at the real home or the real root. Every step uses a scratch root **and** a scratch personal home.

## 1. Daemon tests

```sh
scripts/build-cache.sh swift test --package-path Packages/AgentsKit --filter ChatProject
```

Lease "build" first. Expected, one test each:

- No personal home → no folder, no record, state `noPersonalHome`.
- Fresh home → `<home>/.agents/chat` exists, with `.agents/` and `AGENTS.md`, and `AGENTS.md` holds the shared-folder sentence. One record, and `projects/list` marks it `isChat`.
- Second start → no file changes. Compare modification times and contents.
- Archived record → nothing made, state `archived`, project still archived.
- Live record, folder deleted → folder made again, no `AGENTS.md` written.
- Path is a file → state `failed`, daemon starts, and other projects list normally.
- Personal reconcile with `chat/` present → `chat/` untouched.
- A move into a worktree from a session in the chat project → refused with the sentence.

## 2. Mac walk (run-app skill)

Launch on a scratch root with `AGENTS_PERSONAL_HOME=/tmp/run-229/home`. Then:

1. The sidebar shows **chat** as a project.
2. Choose File ▸ New Chat (⇧⌘N). The new-session form opens on **chat**, with no worktree choice.
3. Send with the echo runtime (`AGENTS_TEST_RUNTIME=echo`). The agent's folder is `/tmp/run-229/home/.agents/chat`.
4. Open the Changes pane. It reads "this folder isn't tracked by git".
5. Archive the **chat** project and relaunch the daemon. It stays archived, and New Chat offers Unarchive.
6. Launch without `AGENTS_PERSONAL_HOME`. There is no **chat** project, and New Chat is disabled with its reason.

## 3. Web walk

On the same scratch set-up, open the web page.

1. The + menu has New Chat, which opens the form on **chat**.
2. The Changes view reads "This folder is not a Git repository."

## 4. Server

Use the test-servers skill with the devbox and a scratch home there. Expected:

- The server lists `devbox:chat`.
- New Chat on ▸ devbox starts there.
- Its folder is the server's `~/.agents/chat`.

## 5. Remote

Build only (`generic/platform=iOS Simulator`). The phone look is Alex's: New Chat in the sidebar toolbar, with a host menu when there are several.
