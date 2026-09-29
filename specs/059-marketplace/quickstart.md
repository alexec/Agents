# 059 · Quickstart: proving it works

Every step runs on a scratch root with a scratch personal home, so the real `~/.agents`, the real
daemon and the person's own skills are never touched (FR-024). The contracts these steps check
are in [contracts/](contracts/). The shapes are in [data-model.md](data-model.md).

## 0 · Golden values (once, before the hash code is written)

Produce the expected hashes with the tools that define them. Commit them as test fixtures under
`Packages/AgentsKit/Tests/AgentsKitTests/Catalog/Fixtures/`.

- **Project `computedHash`.** Run the CLI's `computeSkillFolderHash` algorithm, copied from
  `cli.mjs` into a ten-line `node` script, over three fixture folders:
  - plain ASCII names;
  - mixed-case names, `_` and `-`;
  - a nested `scripts/` folder and a binary file.

  This proves Swift's order equals JS `localeCompare` for these names.
- **Tree SHA.** Run `git add -A && git write-tree` in a temp repo holding each fixture, then
  `git rev-parse HEAD:<folder>`.
- **One real skill.** `avdlee/swiftui-agent-skill@b24e68a`, folder tree SHA `4b58ee6b…`, as
  measured in research R3.

`swift test --filter Catalog` must pass against these values before anything else is built.

## 1 · Fixture server

`specs/059-marketplace/walk/fixture-server.py` is a small `http.server` that stands in for:

- skills.sh: `/api/search` and `/api/download/<o>/<r>/<slug>`;
- github.com: `/<o>/<r>.git/info/refs?service=git-upload-pack`;
- api.github.com: `/repos/<o>/<r>/git/trees/<sha>` and `/repos/<o>/<r>/commits`;
- raw: `/<o>/<r>/<sha>/<path>`.

It serves them from a fixture repo on disk. `POST /_advance` moves HEAD on by one commit that
changes SKILL.md, for US3. `POST /_down` makes every route answer 503, for US4.

```sh
python3 specs/059-marketplace/walk/fixture-server.py --port 8931 &
```

## 2 · Launch a scratch app pointed at it

```sh
S=.claude/skills/run-app/scripts
HOME2=/tmp/run-059-home && mkdir -p $HOME2
eval "$($S/launch.sh --slug 059 \
  --env AGENTS_PERSONAL_HOME=$HOME2 \
  --env AGENTS_TEST_CATALOG_URL=http://127.0.0.1:8931 \
  --env AGENTS_TEST_GITHUB_URL=http://127.0.0.1:8931)"
mkdir -p $ROOT/work && git -C $ROOT/work init -q
$S/rpc.py $ROOT call projects/add "{\"folder\":\"file://$ROOT/work\"}"
```

## 3 · Over the socket (no screen needed)

| # | Call | Expect |
|---|---|---|
| 1 | `catalog/search {"query":"swiftui"}` | Fixture rows in fixture order; `known` true only for known owners |
| 2 | `catalog/preview` of row 1, personal | `commit` = the fixture HEAD; `files` include the PNG with `via: raw`; `runnable` true on `scripts/lint.sh`; `destinationState.free` |
| 3 | `skills/add {previewID, personal}` | `$HOME2/.agents/skills/<name>` holds exactly the previewed files; `$HOME2/.agents/.skill-lock.json` has the entry from contracts/lock-files.md; `$ROOT/catalog-skills.json` has the commit |
| 4 | `personal/shared` | The skill is listed with `managed.source` |
| 5 | Start a Claude agent: `$S/rpc.py $ROOT start claude $ROOT/work "Do you have a skill called <name>? Answer yes or no." 120` | "yes". `$HOME2/.claude/skills/<name>` is a link (054) |
| 6 | Preview the same skill with a **project** destination (`$ROOT/work`), then `skills/add` | `$ROOT/work/.agents/skills/<name>`; `skills-lock.json` at `$ROOT/work` matches `computedHash`; `git -C $ROOT/work status --porcelain` shows both untracked; no commit made |
| 7 | Hand-make `$HOME2/.agents/skills/review/SKILL.md`, preview a fixture skill named `review` | `destinationState.unmanaged`; `skills/add` refused; the folder unchanged (hash before = after) |
| 8 | `POST /_advance`, then `skills/check-updates personal` | `available`. A second call within the hour makes no request to the fixture (server log) |
| 9 | `skills/update-preview`, then `skills/add replace:true` | The folder matches the new commit; `installedAt` kept, `updatedAt` new |
| 10 | Edit the installed SKILL.md, then `skills/update-preview` | `edited: true` |
| 11 | `skills/remove` | The folder is in `$ROOT/trash/` (a scratch root never uses the real Trash, research R9); lock and sidecar entries gone; after the next session start `$HOME2/.claude/skills/<name>` is gone |
| 12 | `POST /_down`, then `catalog/search` | `error.kind = unreachable`; nothing on disk changed |
| 13 | Kill the daemon during step 3, between the rename and the lock write (test hook `AGENTS_TEST_CATALOG_PAUSE=afterRename`), then relaunch | The destination is as before: no folder, no lock entry (SC-003) |
| 14 | (unit test, not the socket) `ConnectionRole` for `.device` and `.agent` on every `catalog/*` and `skills/*` method | Refused. `rpc.py` only connects as control, so this step is proven in `swift test` |

## 4 · On screen, against the frames

Follow the run-app skill's rules: check the Mac is unlocked and the person is away, lease the
screen, drive by pid with `ui.swift`, and screenshot by window id.

- **Frame A**: Shared ▸ Skills with Add skill… in the bar; the added skill's detail shows From,
  Taken at and Remove; a hand-made skill shows Reveal and Edit only.
- **Frames B and C**: type "swiftui"; results with install counts and **known** marks; open one;
  the script warning; switch Add to and watch the button wording, the dots and the **added** marks
  change without a new search.
- **Frame D**: the project page's Skills section between Workflows and Worktrees; Add skill…
  opens the sheet set to the project.
- **Frame E**: the clash from step 7 and the offline sheet from step 12.

Stop with `$S/stop.sh $ROOT` and kill the fixture server.

## 5 · Interop with the real CLI (SC-005)

On a throwaway `HOME=/tmp/run-059-cli`, with no network fixture, against the real skills.sh and
GitHub:

1. `npx skills add twostraws/swiftui-agent-skill -g -y` adds a skill. Point a scratch app at that
   home: the skill is listed with its source, and Update/Remove are offered.
2. Add a different skill through the scratch app. `HOME=/tmp/run-059-cli npx skills list -g`
   lists it.
3. In a scratch project, add through the app. `npx skills list` run in that project lists it,
   and `npx skills experimental_install` in a fresh clone restores it.

## 6 · Suite

`swift test` in `Packages/AgentsKit`. Compare against main with six full runs if anything looks
flaky (the suite is broadly flaky under load). Build both Xcode schemes one after the other with
plugin validation skipped.
