# Quickstart: proving Projects, not agents

Three scenarios, one per user story, in priority order. Each is a thing to do with your hands and
what should happen. The tests that carry the parts hands cannot reach are named where they belong.

## Before you start

```bash
swift test --package-path Packages/AgentsKit          # the whole suite, no Xcode, no simulator
xcodebuild -project Agents.xcodeproj -scheme Agents \
  -configuration Debug -derivedDataPath build/DD build
pkill -f agentsd; pkill -f "Contents/MacOS/Agents"    # the daemon is long-lived: kill it after a kit change
open build/DD/Build/Products/Debug/Agents.app
```

To see this feature do anything you need agents in more than one folder. If you have been using the
app there already are some. If not:

```bash
mkdir -p ~/tmp/api ~/tmp/web ~/tmp/docs
```

Start one agent in each from the app, give one of them a task that will ask permission, and leave it
asking.

## 1. Pick a project, see what needs you (P1)

**By hand**: open the window. The sidebar lists `api`, `web` and `docs` — three folders, not five
agents. Pick `api`: the panel beside it shows only that project's agents, under "Needs input",
"Working" and "Completed", in that order, with empty groups absent.

The agent you left asking for permission is under "Needs input", at the top. Pick it: the
conversation opens, with the same transcript, prompt bar and controls as before this feature. Answer
the permission: it moves to "Working" while you watch, and the row you have selected stays selected.

While it is working, look at `web`. Give an agent there something that will ask permission. The `api`
row in the sidebar marks itself even though `api` is not selected.

With `api` selected, press the "+" in the toolbar: the new agent starts in `~/tmp/api` without you
picking a folder.

**By test**: `swift test --filter AgentGroup`. The grouping is exhaustive over `AgentState.allCases`
— every state lands in exactly one group. This is the property that stops an agent disappearing, so
it is the first test written.

**By test**: `swift test --filter ProjectNaming`. Two folders called `api` in different parents get
`work/api` and `side/api`; one called `api` on its own stays `api`.

## 2. Put a project away when it is done (P2)

**By hand**: with an agent still working in `api`, try to archive `api` from its row menu. The app
declines and names the agents to stop. Stop them, archive again: `api` leaves the sidebar, and its
agents leave the panel.

Open the "Archived" disclosure at the bottom of the sidebar. `api` is there with when you archived
it. Unarchive it: it comes back, with the same agents, in the same states, and their conversations
intact.

Check nothing moved on disk:

```bash
ls -la ~/tmp/api      # exactly what was there before
```

**By hand**: archive the project you currently have selected. The selection moves to another project
rather than leaving an empty panel.

**By test**: `swift test --filter ProjectArchive`. Archiving with a live agent is refused and the
error names it; archiving with none succeeds and leaves every agent's own state untouched; a restart
of the daemon reads the archived state back.

## 3. Look back at agents you archived (P3)

**By hand**: in a project with a dozen finished agents, archive several of them. Turn on the
"Archived" disclosure at the bottom of the panel. The ones you just archived are at the top, newest
first, ten of them. Press "Show more": the rest arrive. When they are all listed there is no "Show
more" left.

Pick an archived agent: its conversation opens and reads.

Quit and reopen the app. The archived list is still open, and the same project is still selected.

**By hand**: turn the disclosure on in a project with nothing archived. It says so in a sentence
rather than showing an empty box.

## The edges worth doing by hand

```bash
mv ~/tmp/docs ~/tmp/docs-moved
```

The `docs` project is still listed, marked missing, dimmed. Its agents and their conversations still
read. Starting a new agent in it is refused with "…is not there any more." — the guard `agents/start`
already had; what is new is that the sidebar said so first.

```bash
mkdir -p ~/tmp/other/api      # a second folder called api
```

Start an agent there. Both rows now say enough of the path to tell them apart. Archive one: the other
goes back to plain `api`.

Start an agent in `~/tmp/api/sub`. It is a project called `sub`, not part of `api`.

## What proves it is done

Every acceptance scenario in [spec.md](./spec.md) has been walked, and:

```bash
swift test --package-path Packages/AgentsKit          # green, including the new suites
```

New test files, all in `Packages/AgentsKit/Tests/AgentsKitTests/`:

| File | Covers |
|---|---|
| `Unit/AgentGroupTests.swift` | Exhaustive over `AgentState`; ordering within a group. |
| `Unit/ProjectNamingTests.swift` | Collisions, nesting, root folders, case. |
| `Unit/ProjectTests.swift` | Folder standardisation, identity, unknown-field round trip. |
| `Integration/ProjectsTests.swift` | list, add, archive, unarchive, the refusal, notifications, restart. |
| `Integration/ProjectMigrationTests.swift` | Agents written before this feature appear under a project with nothing to run. |
