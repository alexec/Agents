# One forge interface (#4329)

Part of the epic #4327. This is a spike, so it adds no product code. It sets these items:

1. The Go interface that every forge implements.
2. How a forge says what it does not do.
3. The new fields that the Work wireframes need.
4. One conformance test for every forge.
5. The order of the move, and what happens to the MCP Apps pages.

The last section gives the tasks for the lead to file.

The epic already decided that the interface is in the daemon, behind the `forge/*` wire
methods, and that the wire keeps one model (`wire.ForgeItem`, #3129). This spec keeps to
that decision. It changes no principle of `docs/explanation/direction.md`: the forge
tokens stay on the machine, and the control plane still holds none of them.

## Where we are

The wire has one model. The daemon has eight interfaces, and each one has its own types:

| Forge | Interface | Reads | Writes | What it does not do |
|---|---|---|---|---|
| GitHub | `forgeGitHub` + `forgeGitHubWrites` (`forge.go`, `forgewrite.go`) | one search for all repos | all | none |
| GitLab | `forgeGitLab` + `forgeGitLabWrites` | a call per project | all | none |
| Forgejo / Gitea | `forgeForgejo` (`forgeforgejo.go`) | a call per repo | all except rerun and log | rerun, log (`forgejoNoChecksAPI`) |
| Bitbucket Cloud | `forgeBitbucket` (`forgebitbucket.go`) | a call per repo | all except auto-merge and PR labels | auto-merge (`bitbucketNoAutoMerge`), labels on a PR (`NoPRLabels`), plans (`bitbucketNoPlan`) |
| Azure Repos | `forgeAzureDevOps` (`forgeazuredevops.go`) | pull requests only, a call per repo | all | issues (Azure Boards has them) |
| Linear | `forgeLinear` + `forgeLinearWrites` | issues only, one query for all teams | comment, labels, close, plan | pull requests |
| Jira | `forgeJira` | issues only, one search | comment, labels, close, transition, plan | pull requests |
| Azure Boards | `forgeAzureBoards` (`forgeazure.go`) | work items only, one query | comment, tags, close, transition, plan | pull requests |

The forge is chosen in five places, each with its own `if` or `switch`:

- `forgeList` (`forge.go`): one block per forge, each with its own `SearchFilter`.
- `forgeItem` (`forge.go`): a chain of `…OfNode` parsers, then `githubItem`, `gitlabItem` and the others.
- `forgeTargetOf` and each write (`forgewrite.go`): `forgeTarget` has one field per forge, and each write has a `switch` with eight cases.
- `forgePlan` and the plan writes (`forgeplan.go`, `forgeplanwrite.go`, `forgestanding.go`).
- `forgeCursor`: one field per forge.

A forge reports what it does not do with an error after the click. The clients cannot hide
a control that the forge does not have. They only see that `mergeMethods` or `transitions`
is missing.

## The interface

Decided: **one interface, `Forge`, with every operation on it.** Each forge embeds
`forgeNone`, which returns `errForgeCannot` for each operation that the forge does not
override. `Caps()` gives the same information as data. I picked this because it keeps one
interface (the issue asks for one), it keeps each forge's file small, and the conformance
test can prove that `Caps()` and the methods agree. Alex can overrule.

I did not pick small optional interfaces found by a type assertion (`forgeMerger` and
others). Some forges do part of an operation: Bitbucket merges but has no auto-merge, and
labels issues but not PRs. A type assertion cannot show this, so a capability struct is
necessary in either design.

The interface is in `Go/internal/agentsd/forgeiface.go`, not in a package of its own. It
needs the daemon's folder config, connections and secrets. The `*mcp` packages stay as the
forge clients under it, as they are now.

```go
// Forge is one forge or tracker behind the forge/* methods (#4329). It speaks the wire's
// types. A method that the forge cannot do returns errForgeCannot with the reason, and
// Caps says so first, so a client hides the control.
type Forge interface {
	// Name is the forge's name on the wire: github, gitlab, forgejo, bitbucket,
	// azuredevops, linear, jira, azureboards. It is the prefix of its lineage refs and
	// its key in a list's cursor and in ForgeListError.forge.
	Name() string
	Caps() forgeCaps
	// Owns parses a node that is this forge's.
	Owns(node wire.LineageNode) (forgeRef, bool)
	// Sources is what a list of these folders reads, with a folder for each repo, team
	// or project. err says why some folders are left out (another GitLab, no sign-in).
	Sources(ctx context.Context, folders []string, prs bool) (forgeScope, error)

	// The reads.
	List(ctx context.Context, s forgeScope, f forgeFilter, cursor string, limit int) (forgePage, error)
	Item(ctx context.Context, r forgeRef, cursor string) (wire.ForgeItemDetail, error)
	Labels(ctx context.Context, r forgeRef) ([]wire.ForgeLabel, error)
	Plan(ctx context.Context, r forgeRef) (forgePlanAnswer, error)
	Blockers(ctx context.Context, children []forgeRef) (map[forgeRef][]wire.LineageNode, error)
	Diff(ctx context.Context, r forgeRef) (wire.ForgeDiff, error)
	Log(ctx context.Context, r forgeRef, check string) (wire.ForgeLog, error)

	// The writes: a person's own clicks (forgewrite.go's rules do not change).
	Comment(ctx context.Context, r forgeRef, body string) (wire.ForgeDone, error)
	SetLabels(ctx context.Context, r forgeRef, add, remove []string) error
	SetState(ctx context.Context, r forgeRef, closed bool, transition string) error
	Merge(ctx context.Context, r forgeRef, sha, method string, auto bool) (wire.ForgeDone, error)
	Approve(ctx context.Context, r forgeRef, sha string) (wire.ForgeDone, error)
	Rerun(ctx context.Context, r forgeRef) (wire.ForgeDone, error)
	AddChild(ctx context.Context, epic forgeRef, child forgeChild) (wire.ForgeDone, error)
	SetBlockedBy(ctx context.Context, r, blocker forgeRef, blocked bool) error
}
```

The types that the interface adds are small. They are not a copy of each forge's types:

- `forgeRef`: `Node wire.LineageNode`, and the forge's own parts of it: `Repo` (owner/repo, a project, organization/project), `Number` and `Key` (ENG-12, PROJ-3). It is the key of a map, so it holds no slices.
- `forgeScope`: what `Sources` found, and `Key() []any` for the list cache. The forge keeps its own fields in it (repos, teams, projects, the folder of each) behind one interface: `forgeScope interface{ Key() []any; Empty() bool }`.
- `forgeFilter`: the fields of `wire.ForgeListRequest` (`prs`, `state`, `label`, `assignee`, `query`, `feature`) and the board's scope (`forgeBoard`), one struct for all forges in place of eight `SearchFilter`s.
- `forgePage`: as now (`items`, `cursors`, `next`, `err`), with items in `wire.ForgeItem`. `mergeForgePages` does not change.
- `forgePlanAnswer` and `planChild`: as now.
- `forgeChild`: the title, the labels and the level of a new child, or an existing ref to add.

The registry is `d.forges() []Forge`, in a fixed order, built from the `newForge…`
constructors that the tests already replace. Each `switch` above becomes a loop:

```go
for _, f := range d.forges() {
	if r, ok := f.Owns(node); ok {
		return f, r, nil
	}
}
```

`forgeCursor` becomes `map[string]string` and `done`, with the same JSON keys as now.
Thus a cursor from an earlier daemon still reads.

These stay off the interface. They are not part of the Work pages:

- The forge-specific methods for lineage (`Node`, `CommitTime`, `Compare`, `CommitPR`, `CostComment`, `Milestones`). They go onto an interface of their own in a later epic, not this one.
- GitHub's other methods: `WaitingDeploys`, `Tags`, `Timeline`, the CI secrets, `MakeRepository`, `SetBody`, `Unassign`. They stay on `forgeGitHub`. The GitHub adapter holds a `forgeGitHub` and the rest of the daemon can still use it.
- Board scopes (`GroupBoard`, `BoardFilter`, `TeamAreas`). These go through `forgeFilter.board`, and each forge reads its own.

## Capabilities

```go
type forgeCaps struct {
	Issues, PRs bool
	// Writes, by kind: an issue's and a pull request's actions.
	Issue, PR forgeActions
	// The fields a forge fills (see "The new fields").
	LabelColors, Avatars, StateReason bool
	// CommentCount is "exact", "capped" (at CommentsMost, Linear's 50) or "detail"
	// (only on an item's own page: Bitbucket issues, Azure Repos).
	CommentCount string
	CommentsMost int
	// Plans: sub-issues, blocked-by, a new child.
	Plan, BlockedBy, AddChild bool
	// Reasons say why an action is missing, in the words a person reads, as
	// bitbucketNoAutoMerge says it now.
	Reasons map[string]string
}

type forgeActions struct {
	Comment, Label, Close, Reopen, Transition, Merge, AutoMerge, Approve, Rerun, Log, Diff bool
}
```

The capabilities go to the clients in two places. Both are new optional fields, so an
earlier client ignores them and an earlier daemon leaves them out:

1. **`ForgeList.forges`**: one `ForgeCapabilities` for each forge on the page: `forge`, `issues`, `pulls`, `labelColors`, `avatars`, `stateReason`, `commentCount`. With this, the list hides what a forge does not fill. For example, it shows no comment count on a Bitbucket issue row and no "not planned" icon on GitLab.
2. **`ForgeItemDetail.actions`**: the actions that this item allows now, by name: `comment`, `label`, `close`, `reopen`, `transition`, `merge`, `autoMerge`, `approve`, `rerun`, `log`, `diff`, `addChild`, `blockedBy`. The daemon makes it from `Caps()` and the item's state. For example, a merged PR has no `merge` and no `reopen`, and a closed item has no `close`. The page shows only these controls. When `actions` is missing (an earlier daemon), the page shows what it shows now.

A call to an action that is not in `actions` still returns `Invalid` with the reason from
`Caps().Reasons`. This covers an earlier client.

The wire's host capability (`forgeWrite1` and the others) does not change. It says what
the daemon can do. The new fields say what one forge, or one item, can do.

## The new fields

The wireframes need four fields. Two are on the wire already. The interface makes each
forge fill them, or say in `Caps()` that it cannot.

| Field | On the wire | GitHub | GitLab | Forgejo | Bitbucket | Azure Repos | Linear | Jira | Azure Boards |
|---|---|---|---|---|---|---|---|---|---|
| **Label colour** | `ForgeLabel.color` (#2956), there | yes | yes | yes | cannot: kind and component have no colour | cannot: tags have no colour | yes | cannot: labels have no colour | cannot: tags have no colour |
| **Comment count** | `ForgeItem.comments`, there | exact | exact | exact | PRs exact; issues on their page only | on its page only | capped at 50 | exact | exact (`System.CommentCount`) |
| **Author avatar** | new: `ForgeItem.authorAvatar`, `ForgeComment.avatar` | `avatarUrl` | `avatar_url` | `avatar_url` | `links.avatar.href` | `imageUrl` | `avatarUrl` | `avatarUrls["48x48"]` | `imageUrl` of the identity |
| **State reason** | new: `ForgeItem.stateReason`, of a closed issue: `completed`, `not_planned`, `duplicate` | `stateReason` | cannot (no reason on close) | cannot | from the state: resolved → completed; wontfix, invalid → not_planned; duplicate | cannot (PRs only) | the state's type: completed, or canceled → not_planned; duplicate when `duplicateOf` is set | the resolution's category | `System.Reason`, or the state Removed → not_planned |

Rules for the fields:

- **An avatar is a URL that only `forge/image` reads (#4009).** A client never loads it itself. Each forge adds its avatar hosts to its `forgeImageHost` in the same task. A self-hosted GitLab or Forgejo uses its own root. A Gravatar URL (`secure.gravatar.com`, which GitLab and Forgejo can give) is read with no token. The clients draw initials when there is no avatar or the read fails.
- **A colour is `#rrggbb`.** A forge that gives `rrggbb` with no `#`, or a name, changes it in its adapter. When `labelColors` is false, the client draws a neutral chip. The shared-parts spike decides that chip.
- **The comment count stays a required `int64`.** A missing count would break an earlier client's decoder. `commentCount` in `ForgeList.forges` tells the client how to read it: `capped` shows "50+" at the cap, and `detail` hides the count on the row.
- **`stateReason` is only on a closed issue.** A pull request's merged or closed state is already in `state`.

## The conformance test

`forgeconformance_test.go` has one table, with one row for each forge. Each row gives the
forge's fake (the fakes in the tests already exist) with fixed data: one open issue, one
closed issue, one open PR and one merged PR, each where the forge has them. The test runs
these checks on every row:

1. **The node goes round.** `Owns(item.Node)` gives back the ref of each item that `List` and `Item` return, and no other forge owns that node.
2. **`Caps()` agrees with the methods.** Each action that is off returns `errForgeCannot` with a reason that is not empty. Each action that is on does not return it. Issues and PRs agree with the kinds that `List` returns.
3. **The model is filled.** `labels` and `assignees` are not nil. `updatedAt` is set. `state` is `open`, `closed` or `merged`. Each label has a `#rrggbb` colour when `LabelColors` is set. `authorAvatar` is set when `Avatars` is set, and `forge/image` allows its host. `stateReason` is one of the three values when `StateReason` is set, and missing when it is not.
4. **The list pages.** A limit of 1 gives every item once, by the cursors, with no item twice.
5. **`actions` follows the state.** The merged PR has no `merge` and no `reopen`, and the closed issue has `reopen`, not `close`.

A new forge gets its row and passes the test before it gets its own tests.

## The MCP Apps pages

The epic's open question: do the MCP Apps pages of each forge (`Go/internal/*mcp/pages/`,
#3838, #3866, #4098) move onto this interface?

Decided: **no, the pages stay as they are.** The shared layer is the forge client in each
`*mcp` package (for example `githubmcp.RealGitHub`), which is under both the pages and the
`Forge` adapters now. Alex can overrule. The reasons:

- **They run in another place.** A page is a view of the MCP server (SEP-1865). It runs where that connector runs, also for an agent on a server or in a container, with the connector's own sign-in. It calls only its own server's tools (`tools/call` in `bridge.js`). The `Forge` interface is in the daemon, with the machine's connections. If a page used the daemon's interface, the connector would need a channel back to the daemon, or a second token store. Both are against the token rules (#1335, `direction.md`).
- **They are for agents too.** A page can be pinned in a chat, and an agent can show it. The Work pages are for a person and are not offered to an agent. The two have different rules and different users.
- **The cost is low now.** The pages do not change when the Work pages change, and this epic does not need them.

As a result, when a forge's Work pages are complete, its list pages (`issues.html`,
`pulls.html`) show the same thing twice in the app. The lead files one follow-up task, not
in this epic, to decide whether the app opens Work in place of a forge's list page.

### Work in place of the list pages (#4366)

Decided: **Work replaces a forge's list rows in the sidebar, and only those. The pages
stay, and the agents keep all of them.** Alex can overrule. The rule is the same one that
#3131, #3311, #3753, #3786 and #3803 used: when Work lists what a list page lists, in a
folder, the sidebar does not show that page's row (`inWork` in
`Go/internal/agentsd/serverviews.go`). The daemon makes the rows, so the Mac window, the
Remote and the web page all change together.

| What | Now | After #4366 |
|---|---|---|
| GitHub, GitLab, Forgejo, Bitbucket, Azure Repos, Linear: the folder's own repo or workspace | no row; Work | the same |
| Jira, when the folder names `jiraProjects` | a row *and* Work (twice) | no row; Work |
| Azure Boards, when the folder names `azureBoardsProjects` | a row *and* Work (twice) | no row; Work |
| Jira or Azure Boards with no projects named | a row; not in Work | the same: the row stays, because Work does not list it |
| A project's other repo (#2669) | a row | the same: Work lists only the folders' own repos |
| A list page that a person pinned | the pin | the same: a pin is the person's own choice |
| A page that an agent shows or pins in a chat | the page | the same |
| A pull request's page (`pr.html`) | the page | the same: it is not a list |

What the agents keep: every tool and every page of each connector, unchanged. Work is a
person's view in the daemon, and it is not offered to an agent. A page is the connector's
view, and it runs where the connector runs, with its own sign-in (above). So an agent on a
server or in a container still has its pages when the daemon's Work is not there.

The reasons:

- **One place for a person.** The same list in two rows in the sidebar is the "twice" that
  this section names. Work has the plan, the filters and the actions of every forge, from
  one model.
- **Nothing is lost.** A row goes only where Work lists the same items. Where Work does
  not list them (no projects named, a project's other repo), the row stays.
- **No new navigation.** No control, screen or link changes. Two rows go from a list that
  already removes six, and a person can still pin a page. It is easy to undo: one line in
  `inWork`.

Build: #4911.

## The order of the move

Each step is one PR. The moves after the first touch the same files (`forge.go`,
`forgewrite.go`, `forgeplan.go`), so they go one after the other, not at the same time,
as AGENTS.md says for the parts of one spec.

1. **The interface, with GitHub.** Add `Forge`, `forgeCaps`, `forgeNone`, the registry and the conformance test. Move GitHub, the forge most like the model. Each `switch` asks the registry first and keeps its old cases for the forges that have not moved.
2. **GitLab**, then **Forgejo**, then **Bitbucket**, then **Azure Repos**: the forges with PRs, from the most like GitHub to the least like GitHub.
3. **Linear**, then **Jira**, then **Azure Boards**: the trackers with issues only.
4. **Remove the old paths.** Remove the `switch` cases, the eight fields of `forgeTarget` and `forgeCursor`'s fields. Then no file outside a forge's own file names a forge.
5. **The capabilities on the wire**: `ForgeList.forges` and `ForgeItemDetail.actions`, made from `Caps()`.
6. **The fields**, one task each, in every forge at once through the interface: label colour, author avatar, comment count, state reason. Each field task is blocked only by step 5, and they can go at the same time. Each one changes the wire schema, so a conflict in `generated.ts` or `*_gen.go` is settled by `scripts/wire.sh gen` again.

The Work page stories (from the wireframe spikes) are blocked by step 5 and by the field
tasks that they draw.

Each step keeps the tests that each forge has now. A move changes where the code is, not
what it does. The wire stays the same until step 5.

## Tasks for the lead to file

All are `task`, `feature:work`, children of #4327, with `mac: no UI, remote: no UI, web: no UI`
in their commits.

| # | Task | Blocked by |
|---|---|---|
| 1 | Forge interface: `Forge`, `forgeCaps`, the registry and the conformance test, with GitHub moved onto it | — |
| 2 | Forge interface: move GitLab | 1 |
| 3 | Forge interface: move Forgejo / Gitea | 2 |
| 4 | Forge interface: move Bitbucket Cloud (no auto-merge, no PR labels, no plan, as capabilities) | 3 |
| 5 | Forge interface: move Azure Repos (PRs only) | 4 |
| 6 | Forge interface: move Linear (issues only) | 5 |
| 7 | Forge interface: move Jira (issues only, transitions) | 6 |
| 8 | Forge interface: move Azure Boards (work items only, transitions) | 7 |
| 9 | Forge interface: remove the per-forge switches, `forgeTarget`'s fields and `forgeCursor`'s fields | 8 |
| 10 | Wire: `ForgeList.forges` (capabilities per forge) and `ForgeItemDetail.actions`, from `Caps()` | 9 |
| 11 | Field: label colour. Each forge that has colours fills them as `#rrggbb` in a list, on an item's page and in `forge/labels`. The others say `labelColors: false` | 10 |
| 12 | Field: author avatar. `ForgeItem.authorAvatar` and `ForgeComment.avatar` in each forge, and each forge's avatar hosts in `forge/image` | 10 |
| 13 | Field: comment count. The count in each forge's list where its API gives it, and `commentCount` (`exact`, `capped`, `detail`) for each one | 10 |
| 14 | Field: state reason. `ForgeItem.stateReason` (`completed`, `not_planned`, `duplicate`) from GitHub, Bitbucket, Linear, Jira and Azure Boards | 10 |
| 15 | Follow-up, not in this epic: when Work covers a forge, decide whether the app opens Work in place of that forge's MCP list page (#4366: decided above) | — |

The lead can merge 2 to 8 into fewer PRs if the moves are small. The order stays the same.

## Decided (Alex can overrule)

- Decided: one `Forge` interface with every operation, and `forgeNone` and `Caps()` for what a forge cannot do, because it keeps one interface and the conformance test can prove that both agree.
- Decided: the interface is in `agentsd`, not in a package of its own, because it needs the daemon's folders, connections and secrets, and the `*mcp` clients stay under it.
- Decided: the capabilities go on the wire as `ForgeList.forges` and `ForgeItemDetail.actions`, both optional, because an earlier client and an earlier daemon then still work.
- Decided: the comment count stays required, and `commentCount` says how to read it, because making it optional breaks an earlier client's decoder.
- Decided: the MCP Apps pages stay as they are, because they run in the connector with its own sign-in and are for agents as well; the `*mcp` clients are the shared layer.
- Decided: lineage's forge methods stay off this interface, because the epic is about the Work pages.
- Decided (#4366): Work replaces a forge's list rows in the sidebar where Work lists the same items, Jira and Azure Boards too when the folder names their projects; the pages, pins and agents' views stay, because a person then sees each list once and an agent keeps every page.
