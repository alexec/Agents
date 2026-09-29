# 059 · Data model

The files these entities live in are in [contracts/lock-files.md](contracts/lock-files.md), and
the wire shapes are in [contracts/catalog-methods.md](contracts/catalog-methods.md).

## Destination

Where a skill goes.

| Field | Type | Notes |
|---|---|---|
| `kind` | `personal` \| `project` | |
| `folder` | path | Only for `project`. It is the project **or worktree** folder the page shows (FR-017). |

What each kind resolves to:

- **personal**: `<personalHome>/.agents/skills`. `personalHome` is `StoreLocations.personalHome`,
  so a scratch root without `AGENTS_PERSONAL_HOME` has no personal destination at all. The sheet
  then hides "You" and says why.
- **project**: `<folder>/.agents/skills`.

Validation: `folder` must be a project the daemon knows, or a worktree of one. It must be on this
Mac, not a server project (R10).

## CatalogResult

One row in frame B.

| Field | Type | From |
|---|---|---|
| `id` | string | skills.sh `id` (`owner/repo/skillId`) |
| `name` | string | skills.sh `name` |
| `owner`, `repo` | string | skills.sh `source`, split. GitHub only (R1) |
| `skillID` | string | skills.sh `skillId` |
| `installs` | int | skills.sh `installs` |
| `known` | bool | `KnownOwners` contains `owner`, compared case-insensitively (R11) |

The **added** mark is not stored here. The app works it out from `SkillsListing` for the current
destination, so switching destinations needs no new search (US2 #5).

## SkillPreview

Frame C. It stands for one staged folder.

| Field | Type | Notes |
|---|---|---|
| `previewID` | UUID | Names `<root>/catalog-staging/<previewID>/` |
| `result` | CatalogResult | |
| `name` | string | SKILL.md front-matter `name`, put through `toSkillSlug` (R7) |
| `description` | string | Front matter |
| `skillPath` | string | `path/to/SKILL.md` in the repo (R2) |
| `commit` | 40-hex | HEAD when previewed (R3) |
| `committedAt` | date? | Only when `gh` is signed in (R4) |
| `treeSHA` | 40-hex | The folder's git tree SHA at `commit` |
| `computedHash` | 64-hex | The CLI's project hash of the staged folder |
| `files` | [PreviewFile] | Sorted by path |
| `skillMarkdown` | string | For the reader |
| `totalBytes` | int | |
| `problems` | [PreviewProblem] | Any problem means Add is not offered |
| `destinationState` | DestinationState | For the destination asked for |

**PreviewFile**: `path` (string), `bytes` (int), `runnable` (bool: tree mode `100755`, under
`scripts/`, or starts with `#!`), `via` (`snapshot` \| `raw` \| `tarball`, kept for the log).

**PreviewProblem** is one of:

- `noSkillFile`: no SKILL.md, or no `name` or `description` in it
- `notFoundInRepo`: R2 found no folder
- `tooLarge(bytes, files)`: over 10 MB or 500 files
- `skipped([path])`: symbolic links or paths that escape the folder. Shown, not fatal.
- `rateLimited(retryAfter)`: only when the tarball fallback failed as well
- `unreachable(host)`

**DestinationState**:

- `free`
- `sameSkill(update: Bool)`: the lock names the same `source` and `skillPath`. Shown as
  **added**, with Update when `treeSHA` differs.
- `managedOther(source)`: the lock names a different source. Add becomes Replace and needs
  confirming.
- `unmanaged(path)`: a folder with no lock entry. Add is not offered and the app offers Reveal
  instead (US4 #1).

Lifetime: a preview is created by `catalog/preview` and used up by `skills/add`. It is swept after
30 minutes. At most 8 are kept at once, and the oldest is swept first.

## ManagedSkill

A row in Shared ▸ Skills or in the project section that a lock names.

| Field | Type | Notes |
|---|---|---|
| `destination` | Destination | |
| `name` | string | The lock key, which is also the folder name |
| `source` | `owner/repo` | |
| `skillPath` | string | |
| `recordedHash` | string | `skillFolderHash` (tree SHA, personal) or `computedHash` (project) |
| `commit`, `committedAt`, `catalogue` | optional | From the sidecar. Absent for skills the CLI added |
| `edited` | bool | The recomputed hash ≠ `recordedHash` (R6) |
| `update` | UpdateState | |

**UpdateState**:

- `unknown`: not checked yet, or the check failed
- `current`
- `available(commit)`: HEAD has moved and the folder's tree SHA changed

It is checked at most once an hour per `source` (FR-018). A moved HEAD with an unchanged folder
counts as `current`, and the sidecar's `commit` moves forward so the next check needs no API call.

Changes of state:

- `current → available`: the check finds a new tree SHA.
- `available → current`: after `skills/add` with `replace`, which is what Update does.
- Any state → gone: after `skills/remove`.

## SkillsListing

What a page lists.

- **personal**: extends `SharedSnapshot.Skill` (054) with an optional `managed: ManagedSkill`.
  There is no new method: `personal/shared` fills it in.
- **project**: `skills/list {destination}` returns `[ListedSkill]`. Each has `name`,
  `description`, `folder` and an optional `managed`.

## Sidecar record (`<root>/catalog-skills.json`)

Keyed by `"<destinationKey>/<name>"`, where `destinationKey` is `personal` or the project's
standardized folder path.

Each entry has `commit`, `committedAt?`, `treeSHA`, `catalogue` (always `"skills.sh"` in this
slice), `addedAt`.

It is written only after the lock file is. An entry whose lock entry is gone is ignored and
dropped at the next write.
