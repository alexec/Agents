# Quickstart: Proving Retirement Works (051)

Everything here runs on a scratch root. Nothing touches the real store or the real daemon. Start
scratch daemons as the team's notes on driving agentsd by hand say: the real environment minus `CLAUDE_*`, and
held open by a client in the same command, or it exits when idle. Stop them by the pid in the
scratch root's `daemon.lock`, never by name.

The clock is **not** faked on a running daemon. Age is proved by seeding records whose
`archivedAt` is already in the past. Clock jumps, the one-day floor and legacy records are
proved in `RetentionPlanTests`, where the clock is a parameter.

## 0. Prerequisites

- The branch builds: `swift build` in `Packages/AgentsKit`, then the Agents and Remote schemes
  with `-skipPackagePluginValidation`, one after the other.
- `scripts/seed-archived.swift` (added in the Setup phase) writes N agents into a root:
  - `--archived-days-ago D` for the archive age
  - `--transcript-bytes B` for the conversation size
  - `--legacy` to write old records with no `archivedAt`
  - `--live L` for live agents alongside the archived ones
  It writes `agent.json` with real-sized option and command lists (copied from a fixture
  captured from a Claude agent), and `transcript.jsonl` of the given size.

## 1. The pure rules

```sh
cd Packages/AgentsKit && swift test --filter 'RetentionPlan|Tombstone|ArchiveIndex|RetiredStore|AgentStoreSlim'
```

Expected: all pass. The suites cover:

- age, the cap order and its tie-break
- the 24 h floor, including against the cap and a forward clock jump
- a future `archivedAt`
- a restart after the clock was wound forward
- legacy records timed from their first index
- holds taking agents out
- `overCap` naming its reasons
- the tombstone kept under 2 KB
- a slim save keeping the lists on disk
- index rebuild, and `agent.json` winning over a stale index entry
- the retire order with a failure injected after each step, where every outcome leaves either
  the whole agent or a tombstone, never neither (SC-006)

## 2. Retirement on a scratch daemon

```sh
R=/tmp/run-051
scripts/seed-archived.swift --root $R --count 3 --archived-days-ago 31 --transcript-bytes 2000000
scripts/seed-archived.swift --root $R --count 2 --archived-days-ago 29 --transcript-bytes 2000000
scripts/seed-archived.swift --root $R --count 2 --live
```

Start the daemon on `$R`, wait past the 30 s first check, then call `agents/list` and
`agents/retired` over the socket.

Expected:
- The three 31-day agents are gone from `agents/list`, and their directories are gone from
  `$R/agents/`.
- Three tombstones are in `agents/retired` and in `$R/retired.jsonl`.
- The two 29-day agents and the two live ones are untouched (Story 1, scenarios 1–3).
- `retention/state` reports `retiredCount: 3`.

Then:

- **Cap**: call `retention/set { cap: gb1, confirmed: false }` after seeding 600 MB more of
  archived agents at 10 days. Expected: a preview with a count and bytes, and nothing changed.
  Call it again with `confirmed: true`. Expected: the oldest archived agents go until the total
  is under 1 GB, and none archived today goes (Story 2).
- **Off**: set `keepFor: forever, cap: none`. Seed more at 400 days. Expected: nothing retired,
  and the settings summary says "kept forever" (Story 3, scenario 4).
- **Holds**: seed an archived agent at 40 days whose worktree is a real `git worktree` under
  `$R`, with an uncommitted file. Expected: kept, with `retirement: { held: worktreeHasWork }`.
  Commit, merge and remove the worktree. Expected: retired at the next check (Story 5).
- **Retire now**: `agents/retire { confirmed: true }` on a 2-day archived agent. Expected: it is
  retired. Calling it on a live agent fails with `-32051`.
- **Retired id**: `agents/unarchive` on a retired id fails with `-32050`, and the message is the
  retired sentence.

## 3. Start time and memory (SC-003, SC-004)

```sh
scripts/seed-archived.swift --root /tmp/run-051-big --count 1000 --archived-days-ago 3 --transcript-bytes 500000
scripts/seed-archived.swift --root /tmp/run-051-big --count 10 --live
scripts/seed-archived.swift --root /tmp/run-051-small --count 10 --live
```

For each root, start the daemon five times and time from launch to the first `agents/list`
answer. Read the daemon's footprint with `footprint <pid>` after the first list. Do this once
without `archive.json` (first start, which builds the index) and five times with it.

Expected: the median start of `-big` is within 10% of `-small`'s, and its footprint within
20 MB. The first start may be slower, since it builds the index. Record it: it happens once.

Compare the same `-big` root on `main` to show what changed. Main reads all 1,000 records in
full.

## 4. Kill in the middle of retiring (SC-006)

Seed 50 agents at 31 days with 20 MB transcripts, so deleting takes long enough to be caught.
Start the daemon and, while retiring is under way (`daemon.log` says "retiring"), `kill -9` the
pid in `daemon.lock`. Start it again. Expected: for every seeded id, exactly one of these is
true:

- its directory is whole and it is in `agents/list`
- it has a tombstone and no directory

Nothing is half-deleted and still listed, and nothing is gone without a tombstone. Repeat ten
times at different moments.

## 5. The window and the phone (run-app skill)

On `/tmp/run-051` with seeded agents at 25, 27 and 29 days and some already retired:

- **Mac, the project's Archived list**: each row has its note ("Retires in 5 days", "Retires in
  3 days", "Retires tomorrow"), and the list ends "N older agents have been retired."
- **Mac, Settings ▸ Archived agents**: count, size, keep-for and cap. Choosing 7 days opens the
  confirm sheet with the count and size. Screenshot each.
- **Mac, an event that names a retired agent**: following it shows the retired page, not an
  error.
- **Mac, an archived agent's menu**: Retire now, confirmed, removes the row at once. On a held
  agent it is disabled, with the reason as its tooltip.
- **Mac, opening an archived chat**: its command menu is there (it was made whole). After 10
  minutes away, `daemon.log` shows it slimmed again.
- **Phone and iPad**: build Remote for the generic simulator only. The row notes, the retired
  line and the retired page are for Alex to look at on the real devices, batched at the end,
  because an install replaces the Remote Alex uses.

