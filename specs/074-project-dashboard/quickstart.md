# Quickstart: proving the Dashboard

## Unit

```sh
swift test --package-path Packages/AgentsKit --filter Dashboard
scripts/web.sh check
```

Covers: checks and refusals; keepers (agent, workflow, take over); a worktree agent writing the
project folder; same value leaves the file's bytes alone; 100 concurrent sets from 5 agents leave
every file whole; outside edits and broken files; limits; compaction; Remove then a keeper's set
brings it back with the note.

## The walk (run-app, scratch root)

```sh
S=.claude/skills/run-app/scripts
eval "$($S/launch.sh --slug dash)"
mkdir -p $ROOT/work && git -C $ROOT/work init -q
$S/rpc.py $ROOT call projects/add "{\"folder\":\"file://$ROOT/work\"}"
$S/rpc.py $ROOT start claude $ROOT/work "Use set_tile twice: a number tile id open_bugs …, then …" 180
ls $ROOT/work/.agents/dashboard     # open_bugs.json, …
$S/rpc.py $ROOT call dashboard/get "{\"folder\":\"file://$ROOT/work\"}"
```

1. An agent posts two tiles: a big number (`open_bugs`, posted once) and a time series (`tests_passing`, a number tile posted five times, so its points draw a trend line; slice 1 has no multi-line `series`).
2. The Mac's Dashboard row shows "2 tiles"; the page shows both; screenshot by window id.
3. The web page (headless Chrome, `cdp.mjs`) shows the same; screenshot.
4. The Remote builds for the generic simulator (its look is Alex's).
5. `dashboard/remove` the number tile: gone from the page, file gone.
6. A second turn: the agent sets it again; the tool's answer says it had been removed and when;
   the tile is back.
7. `$S/stop.sh $ROOT`.
