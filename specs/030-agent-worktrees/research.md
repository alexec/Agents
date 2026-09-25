# Research: An Agent Can Work in a Worktree of Its Own

Decisions for 030, each with the reason and what else was weighed. Code references are to
`/tmp/w-030` at `9a9c7d9`.

## R1. The app makes the worktree; the runtime is only told where to work

**Decision**: The daemon runs `git worktree add` itself, then starts the runtime with the
worktree as both the process's working folder and the `cwd` in `session/new`. It never passes a
runtime's own worktree option.

**Rationale**: This was tested on 2026-09-24 against a scratch repository, one real start per
runtime, each with `initialize`, `session/new` and one prompt asking the agent its working folder:

| Runtime (version) | Own option over ACP | Result |
|---|---|---|
| Claude (adapter 0.81.2) | `_meta.claudeCode.options.extraArgs.worktree` on `session/new` (the adapter ignores its own argv) | Made `.claude/worktrees/<name>`, locked, and worked there |
| Cursor (`cursor-agent acp`) | `--worktree=<name>`, before or after `acp` | Made `~/.cursor/worktrees/<repo>/<name>`, then worked in the `session/new` cwd. Also printed `Using worktree: …` on stdout, the protocol channel |
| Copilot 1.0.89 (`copilot --acp`) | `--worktree=<name>` (accepted, not in `--help`) | Made `<repo>.worktrees/<name>`, then worked in the `session/new` cwd. Never answered `initialize` when the name was an existing branch |
| Grok (`grok agent stdio`) | `grok --worktree=… agent stdio` / `grok agent --worktree=… stdio` | Ignored / "unexpected argument", exit 2 |

Every runtime used the `cwd` it was given in `session/new`. That is the one thing the four have
in common.

**Alternatives considered**: Per-runtime options behind one switch. Rejected: two of the four
don't work in the worktree, one doesn't work at all, and each option puts its worktrees somewhere
different. A worktree that a runtime makes is invisible to the daemon, so the app couldn't file,
list or clean it up.

## R2. The process starts in the worktree too, so a new worktree takes a fresh session

**Decision**: `freshSession` launches the runtime with `cwd` = the worktree, and `session/new`
names the same folder. So a start into a **new** worktree never reuses the start bar's draft
session, which was made in the project folder before the prompt, and so before the name, existed.
The existing check at `DaemonCore+Commands.swift:157` (`$0.cwd == request.cwd`) already throws such
a draft away. A start into an **existing** worktree sends that worktree as the draft's `cwd`, so
its draft is reused as today.

**Rationale**: The tests above started each process in the folder they then named in
`session/new`, so they never showed which folder a runtime obeys when the two differ. Starting
both in the worktree removes the question. The cost is one runtime start (a few seconds), and only
for a new worktree.

**Alternatives considered**:
- A second `session/new` on the draft's process. Rejected because it's unproven whether all four honour a session folder different from their process folder, and the draft would be left with an orphan session.
- Making the worktree when New worktree is chosen, with a placeholder name, then renaming it at send. Rejected: `git worktree move` plus `branch -m` is two more steps that can fail, and choosing and then backing out would leave worktrees behind.

## R3. Naming from the prompt

**Decision**: `WorktreeName.from(prompt:)` works like this:
1. Lower-case the prompt.
2. Split it on anything that isn't a letter or digit.
3. Drop a small list of filler words: *a an the to of on in for and or with please can could you would we i me my this that it is be*.
4. Take the first four words that are left, join them with `-`, and cut at a hyphen so the result is at most 32 characters.

If nothing is left, the name is `agent-MMdd-HHmm`. The branch is `agents/<name>`. For a clash, the
first free `<name>-2`, `<name>-3`, … is used, checking the folder, the local branch and the names
reserved by starts still in progress.

**Rationale**: Alex chose prompt-derived names (clarification, 2026-09-24). Four words is
enough to tell worktrees apart in `git branch` and short enough for a row badge.
`Agent.fallbackTitle(from:)` already takes words from the prompt for the title, but keeps
casing and punctuation, so it can't be reused as it is.

**Concurrency**: `DaemonCore` is an actor, and two starts can interleave at any `await`. The chosen
name goes into `reservedWorktreeNames` before the first `await` and comes out when
`git worktree add` returns, like 028's `reservedStarts`. `git worktree add -b` also refuses an
existing branch, so a start that still collides tries the next number (at most 20 tries). That
gives SC-003.

## R4. Location and keeping it out of the project

**Decision**: `<toplevel>/.agents/worktrees/<name>`, where `<toplevel>` is
`git -C <project> rev-parse --show-toplevel`. Before the first add, the daemon makes sure
`<git-common-dir>/info/exclude` contains the line `/.agents/worktrees/`, and adds it if not.

**Rationale**: Alex chose this (clarification, 2026-09-24). `info/exclude` is local to the clone and
never committed, which satisfies FR-010. `git status` and ripgrep respect it. The app's own @-mention search skips hidden folders, so it
never walks into `.agents/`. The files pane lists one folder at a time, so `.agents` shows there as
a folder you can open, like `.git`, and nothing is duplicated. Using `--show-toplevel` rather than the main worktree's root means a project that is
itself a linked worktree keeps its agents' worktrees inside itself, where the person looks.

**Alternatives considered**: Adding the line to `.gitignore`. Rejected because that edits a
tracked file. A sibling folder and Application Support were offered to Alex and not chosen.

## R5. Which folder an agent belongs to: `projectFolder`, not `cwd`

**Decision**: Add an optional `worktree: AgentWorktree?` to `Agent`, and a computed
`projectFolder` (`Project.standardize(worktree?.project ?? cwd)`). Every place that uses the
agent's folder to mean *its project* switches to `projectFolder`. Every place that means *where it
works* keeps `cwd`.

Uses that switch to `projectFolder` (from `grep standardize(\$0.cwd)` and friends):
- `DaemonCore+Projects.swift:20` (grouping) and `:150` (archiving a project with live agents)
- `DaemonCore.swift:385` (`projectChanged(forAgentIn:)`)
- `DaemonCore+Attention.swift:91, :121`
- `DaemonCore+Workflows.swift:704`
- `DaemonCore+AppTools.swift:349` (workflows belong to the project)
- `DaemonCore+Helpers.swift:24, :90, :102` and `HelperLimit.swift:29` (028's limit counts the whole project, FR-014)
- `AgentsModel.swift:443`
- `AppModel.swift:699`, `WorkflowPage.swift:382`, `AgentRow.swift:89`
- `Remote/Sources/RemoteModel.swift:370`

Uses that stay on `cwd`: the launch and `continueSession` (`DaemonCore+Commands.swift:623`,
`DaemonCore+Runtimes.swift:164`), `FilesPane.swift:239`, `folderScope`, shells, and the runtime's
session list (FR-015).

**Rationale**: A project is "the union of every folder an agent has run in"
(`DaemonCore+Projects.swift:3`). Without this change, each worktree would become a project of its
own in the sidebar. A single computed property keeps each call site a one-word change and easy to
review.

**Alternatives considered**: Storing the project folder as the agent's `cwd` and the worktree
separately. Rejected: `cwd` is what every runtime path, shell and pane already reads as "where
it works", and flipping its meaning would touch far more code.

## R6. Recognising the app's worktrees without a registry

**Decision**: A worktree counts as the app's when its path is under `<toplevel>/.agents/worktrees/`
**and** its branch starts with `agents/`. Nothing is stored. The list comes from
`git worktree list --porcelain`, with each entry given the agents whose `cwd` is inside it.

**Rationale**: This matches how projects work: "Almost nothing about a project is stored." It also
survives a daemon reset, and FR-021 (never remove what the app didn't make) is a check on the path
and the branch prefix.

## R7. What "merged" means when cleaning up

**Decision**: The base is recorded on the agent (`AgentWorktree.base`, the branch name, or the
commit when HEAD was detached). A worktree's branch counts as merged when
`git merge-base --is-ancestor agents/<name> <base>` succeeds. If no agent record names the worktree
any more, the project folder's current branch is used instead. Uncommitted work is judged by
`git -C <wt> status --porcelain`, which is non-empty when there is any.
- **Clean and merged**: remove it with `git worktree remove` and delete the branch with `git branch -d`.
- **Otherwise**: the app says what would be lost and waits for confirmation, then runs
  `git worktree remove --force` and `git branch -D`.

**Rationale**: FR-020. `-d` refuses an unmerged branch on its own, which is a second guard.

## R8. A worktree that has gone

**Decision**: `liveSession(for:)` checks `isDirectory(agent.cwd)` for an agent that has a
`worktree`, before it launches anything. If the folder is missing, it throws the new
`Failure.worktreeMissing`: "The worktree <name> is gone, so this agent can't be picked up where it
was." It never falls back to the project folder (FR-017). The phone and the Mac show this the way
they show any failed resume.

## R9. Starting from the start bar and from `start_agent`

**Decision**:
- `StartRequest` and `StartHelperRequest` gain `worktree: WorktreeChoice?`, which is `.new` or
  `.existing(URL)`. Leaving it out means the project folder, so older clients are unchanged.
- The start bar's `StartDraft` gains the same field, and it goes back to nil after each start
  (FR-004).
- `start_agent` gains an optional `worktree` string: `"new"`, or the name of an existing worktree
  of the caller's repository. The daemon resolves the name, and refuses one it can't find or one
  outside the repository (US4).

## R10. What git is run, and how

Everything goes through `GitProcess` (027): the person's own git, both pipes drained, finishing
on `terminationHandler` (see memory: `waitUntilExit` hangs off the main thread). The commands:

| Purpose | Command |
|---|---|
| Is it a repository; toplevel; subfolder | `rev-parse --show-toplevel --show-prefix` |
| Where exclude lives | `rev-parse --git-common-dir` |
| Any commit to base on | `rev-parse --verify -q HEAD` |
| Base | `rev-parse --abbrev-ref HEAD` (and `HEAD` when that says `HEAD`) |
| Make | `worktree add -b agents/<name> <path> HEAD` |
| List | `worktree list --porcelain` |
| Uncommitted | `-C <wt> status --porcelain` |
| Merged | `merge-base --is-ancestor agents/<name> <base>` |
| Remove | `worktree remove [--force] <path>`, then `branch -d/-D agents/<name>` |

`worktree add` runs the repository's `post-checkout` hook. A hook that fails fails the start
(FR-013), with git's own message.
