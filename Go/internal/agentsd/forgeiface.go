package agentsd

import (
	"context"
	"errors"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// One forge interface (#4329, specs/4329-forge-interface/spec.md): each forge or tracker behind
// the forge/* methods implements Forge, in the wire's types, and the reads and writes ask the
// registry (d.forges) which forge owns a node, in place of a switch with a case per forge. A
// forge says what it cannot do twice: as data in Caps, so a client hides the control, and as
// errForgeCannot from the method, for an earlier client. The conformance test
// (forgeconformance_test.go) proves that the two agree on every forge.
//
// The forges moved onto it one at a time (#4352–#4359); Azure Boards was the last.

// Forge is one forge or tracker behind the forge/* methods (#4329). It speaks the wire's types. A
// method that the forge cannot do returns errForgeCannot with the reason, and Caps says so first,
// so a client hides the control.
type Forge interface {
	// Name is the forge's name on the wire: github, gitlab, forgejo, bitbucket, azuredevops,
	// linear, jira, azureboards. It is the prefix of its lineage refs and its key in a list's
	// cursor and in ForgeListError.forge.
	Name() string
	Caps() forgeCaps
	// Images are the forge's image hosts and its token for them (#4544), which forge/image reads:
	// the URLs of its attachments and avatars. nil when it has none of its own.
	Images() forgeImageHost
	// Owns parses a node of an issue or a pull request that is this forge's.
	Owns(node wire.LineageNode) (forgeRef, bool)
	// Sources is what a list of these folders reads, with a folder for each repo, team or
	// project. err says why some folders are left out (another GitLab, no sign-in).
	Sources(ctx context.Context, folders []string, prs bool) (forgeScope, error)

	// The reads.
	List(ctx context.Context, s forgeScope, f forgeFilter, cursor string, limit int) (forgePage, error)
	Item(ctx context.Context, r forgeRef, cursor string) (wire.ForgeItemDetail, error)
	Labels(ctx context.Context, r forgeRef) ([]wire.ForgeLabel, error)
	Plan(ctx context.Context, r forgeRef) (forgePlanAnswer, error)
	// Blockers are the blockers of a standing epic's children, which a list does not read: one
	// read for all of them. A blocker says whether it is open, as a plan's does.
	Blockers(ctx context.Context, children []forgeRef) (map[forgeRef][]planRef, error)
	Diff(ctx context.Context, r forgeRef) (wire.ForgeDiff, error)
	Log(ctx context.Context, r forgeRef, check string) (wire.ForgeLog, error)
	// Releases are the releases of the scope's repos (#4426), at most limit of each, with their
	// nodes; Latest is left to forge/releases. ReleaseCommits are the commits of repo (as a node
	// names it) in head and not in base, oldest first, and the forge's page of the range. A forge
	// with no releases says so in Caps: Releases false, and why in Reasons.
	Releases(ctx context.Context, s forgeScope, limit int) ([]wire.ForgeRelease, error)
	ReleaseCommits(ctx context.Context, repo, base, head string) ([]compareCommit, string, error)

	// The writes: a person's own clicks (forgewrite.go's rules do not change).
	Comment(ctx context.Context, r forgeRef, body string) (wire.ForgeDone, error)
	SetLabels(ctx context.Context, r forgeRef, add, remove []string) error
	// SetAssignees assigns people to an item and takes others off it, by their logins (#4403).
	SetAssignees(ctx context.Context, r forgeRef, add, remove []string) error
	SetState(ctx context.Context, r forgeRef, closed bool, transition string) error
	Merge(ctx context.Context, r forgeRef, sha, method string, auto bool) (wire.ForgeDone, error)
	Approve(ctx context.Context, r forgeRef, sha string) (wire.ForgeDone, error)
	Rerun(ctx context.Context, r forgeRef) (wire.ForgeDone, error)
	AddChild(ctx context.Context, epic forgeRef, child forgeChild) (wire.ForgeDone, error)
	SetBlockedBy(ctx context.Context, r, blocker forgeRef, blocked bool) error
}

// forgeCaps is what a forge does, as data (#4329): the clients hide what it does not.
type forgeCaps struct {
	Issues, PRs bool
	// Writes, by kind: an issue's and a pull request's actions.
	Issue, PR forgeActions
	// The fields a forge fills (the spec's "The new fields").
	LabelColors, Avatars, StateReason bool
	// CreatedAt: items say when they opened; ClosedAt: closed and merged items say when they
	// closed. Children, LinkedPulls and Events: an issue's read has its sub-issues, the pull
	// requests that close it, and its timeline (#4373).
	CreatedAt, ClosedAt, Children, LinkedPulls, Events bool
	// A pull request's (#4409): Branches, its head and base branches; MergedBy and MergeCommit, a
	// merged one's; Size, Reviewers and Closes, on its read; CheckTimes, its checks' times.
	Branches, MergedBy, MergeCommit, Size, Reviewers, Closes, CheckTimes bool
	// CommentCount is "exact", "capped" (at CommentsMost, Linear's 50) or "detail" (only on an
	// item's own page: Bitbucket issues, Azure Repos).
	CommentCount string
	CommentsMost int
	// Total: a list's first page says how many items the whole list has (forgePage.total, #4396).
	// A forge without it has a total only when its list ends on its first page.
	Total bool
	// Plans: sub-issues, blocked-by, a new child.
	Plan, BlockedBy, AddChild bool
	// Releases: forge/releases and forge/release read its releases (#4426).
	Releases bool
	// Reasons say why an action is missing, by the action's name, in the words a person reads,
	// as bitbucketNoAutoMerge says it now.
	Reasons map[string]string
}

// forgeActions are the writes a forge allows on one kind of item.
type forgeActions struct {
	Comment, Label, Assign, Close, Reopen, Transition, Merge, AutoMerge, Approve, Rerun, Log, Diff bool
}

// The actions' names, as forgeCaps.Reasons and errForgeCannot name them.
const (
	actionComment    = "comment"
	actionLabel      = "label"
	actionAssign     = "assign"
	actionClose      = "close"
	actionReopen     = "reopen"
	actionTransition = "transition"
	actionMerge      = "merge"
	actionAutoMerge  = "autoMerge"
	actionApprove    = "approve"
	actionRerun      = "rerun"
	actionLog        = "log"
	actionDiff       = "diff"
	actionPlan       = "plan"
	actionAddChild   = "addChild"
	actionBlockedBy  = "blockedBy"
	actionReleases   = "releases"
)

// on says whether the actions allow the action of that name.
func (a forgeActions) on(action string) bool {
	return map[string]bool{actionComment: a.Comment, actionLabel: a.Label, actionAssign: a.Assign, actionClose: a.Close, actionReopen: a.Reopen,
		actionTransition: a.Transition, actionMerge: a.Merge, actionAutoMerge: a.AutoMerge, actionApprove: a.Approve,
		actionRerun: a.Rerun, actionLog: a.Log, actionDiff: a.Diff}[action]
}

// wire is the capabilities of the forge called name as ForgeList.forges says them (#4361).
func (c forgeCaps) wire(name string) wire.ForgeCapabilities {
	out := wire.ForgeCapabilities{Forge: name, Issues: c.Issues, Pulls: c.PRs, LabelColors: c.LabelColors,
		Avatars: c.Avatars, StateReason: c.StateReason, CommentCount: wire.ForgeCommentCount(c.CommentCount)}
	if c.CommentsMost > 0 {
		out.CommentsMost = new(int64(c.CommentsMost))
	}
	// An earlier daemon leaves these out, which a client reads as false, so only true is sent.
	for _, f := range []struct {
		on  bool
		out **bool
	}{{c.CreatedAt, &out.CreatedAt}, {c.ClosedAt, &out.ClosedAt}, {c.Children, &out.Children}, {c.LinkedPulls, &out.LinkedPulls}, {c.Events, &out.Events}, {c.Total, &out.Total}, {c.Releases, &out.Releases},
		{c.Branches, &out.Branches}, {c.MergedBy, &out.MergedBy}, {c.MergeCommit, &out.MergeCommit}, {c.Size, &out.Size},
		{c.Reviewers, &out.Reviewers}, {c.Closes, &out.Closes}, {c.CheckTimes, &out.CheckTimes}} {
		if f.on {
			*f.out = new(true)
		}
	}
	return out
}

// itemActions are what the page of item allows now (#4361), from c and the item's state: only an
// open item closes, merges, auto-merges, is approved or runs its checks again, and only a closed
// one reopens (a merged pull request does not). A transition needs a move that the workflow
// allows now; a plan's writes are an issue's.
func (c forgeCaps) itemActions(d wire.ForgeItemDetail) []wire.ForgeAction {
	i := d.Item
	a := c.Issue
	if i.Node.Kind == lineage.KindPR {
		a = c.PR
	}
	open := i.State == "open"
	issue := i.Node.Kind == lineage.KindIssue
	out := []wire.ForgeAction{}
	for _, on := range []struct {
		action wire.ForgeAction
		on     bool
	}{
		{wire.ForgeActionComment, a.Comment},
		{wire.ForgeActionLabel, a.Label},
		{wire.ForgeActionAssign, a.Assign},
		{wire.ForgeActionClose, a.Close && open},
		{wire.ForgeActionReopen, a.Reopen && i.State == "closed"},
		{wire.ForgeActionTransition, a.Transition && len(d.Transitions) > 0},
		{wire.ForgeActionMerge, a.Merge && open},
		{wire.ForgeActionAutoMerge, a.AutoMerge && open},
		{wire.ForgeActionApprove, a.Approve && open},
		{wire.ForgeActionRerun, a.Rerun && open},
		{wire.ForgeActionLog, a.Log},
		{wire.ForgeActionDiff, a.Diff},
		{wire.ForgeActionAddChild, c.AddChild && issue},
		{wire.ForgeActionBlockedBy, c.BlockedBy && issue},
	} {
		if on.on {
			out = append(out, on.action)
		}
	}
	return out
}

// errForgeCannot is what a forge's method gives for an action that the forge does not do;
// errors.Is finds it in a forgeCannot.
var errForgeCannot = errors.New("the forge cannot do this")

// forgeCannot is an action a forge cannot do, and why. A forge's own reason goes in reason;
// forgeNone leaves it empty, and forgeCannotErr fills it from Caps().Reasons.
type forgeCannot struct{ action, reason string }

func (e *forgeCannot) Error() string {
	if e.reason != "" {
		return e.reason
	}
	return "the forge cannot " + e.action
}

func (e *forgeCannot) Is(target error) bool { return target == errForgeCannot }

func cannot(action string) error { return &forgeCannot{action: action} }

// forgeCannotErr is err as a method's answer: an action that f cannot do is Invalid, with the
// reason that f's Caps says for it.
func forgeCannotErr(method string, f Forge, err error) error {
	var c *forgeCannot
	if !errors.As(err, &c) {
		return err
	}
	reason := c.reason
	if reason == "" {
		reason = f.Caps().Reasons[c.action]
	}
	if reason == "" {
		reason = c.Error()
	}
	return Invalid("%s: %s", method, reason)
}

// forgeNone is every operation that a forge does not override: each says it cannot. A forge
// embeds it, so a new operation on Forge is "cannot" on every forge until it is written.
type forgeNone struct{}

func (forgeNone) Images() forgeImageHost { return nil }

func (forgeNone) List(context.Context, forgeScope, forgeFilter, string, int) (forgePage, error) {
	return forgePage{}, nil
}
func (forgeNone) Item(context.Context, forgeRef, string) (wire.ForgeItemDetail, error) {
	return wire.ForgeItemDetail{}, cannot("read")
}
func (forgeNone) Labels(context.Context, forgeRef) ([]wire.ForgeLabel, error) {
	return nil, cannot(actionLabel)
}
func (forgeNone) Plan(context.Context, forgeRef) (forgePlanAnswer, error) {
	return forgePlanAnswer{}, cannot(actionPlan)
}
func (forgeNone) Blockers(context.Context, []forgeRef) (map[forgeRef][]planRef, error) {
	return nil, nil
}
func (forgeNone) Diff(context.Context, forgeRef) (wire.ForgeDiff, error) {
	return wire.ForgeDiff{}, cannot(actionDiff)
}
func (forgeNone) Log(context.Context, forgeRef, string) (wire.ForgeLog, error) {
	return wire.ForgeLog{}, cannot(actionLog)
}
func (forgeNone) Releases(context.Context, forgeScope, int) ([]wire.ForgeRelease, error) {
	return nil, cannot(actionReleases)
}
func (forgeNone) ReleaseCommits(context.Context, string, string, string) ([]compareCommit, string, error) {
	return nil, "", cannot(actionReleases)
}
func (forgeNone) Comment(context.Context, forgeRef, string) (wire.ForgeDone, error) {
	return wire.ForgeDone{}, cannot(actionComment)
}
func (forgeNone) SetLabels(context.Context, forgeRef, []string, []string) error {
	return cannot(actionLabel)
}
func (forgeNone) SetAssignees(context.Context, forgeRef, []string, []string) error {
	return cannot(actionAssign)
}
func (forgeNone) SetState(_ context.Context, _ forgeRef, closed bool, transition string) error {
	switch {
	case transition != "":
		return cannot(actionTransition)
	case closed:
		return cannot(actionClose)
	}
	return cannot(actionReopen)
}
func (forgeNone) Merge(context.Context, forgeRef, string, string, bool) (wire.ForgeDone, error) {
	return wire.ForgeDone{}, cannot(actionMerge)
}
func (forgeNone) Approve(context.Context, forgeRef, string) (wire.ForgeDone, error) {
	return wire.ForgeDone{}, cannot(actionApprove)
}
func (forgeNone) Rerun(context.Context, forgeRef) (wire.ForgeDone, error) {
	return wire.ForgeDone{}, cannot(actionRerun)
}
func (forgeNone) AddChild(context.Context, forgeRef, forgeChild) (wire.ForgeDone, error) {
	return wire.ForgeDone{}, cannot(actionAddChild)
}
func (forgeNone) SetBlockedBy(context.Context, forgeRef, forgeRef, bool) error {
	return cannot(actionBlockedBy)
}

// forgeRef is an item on one forge: its node, and the forge's own parts of it. It is the key of
// a map, so it holds no slices.
type forgeRef struct {
	Node wire.LineageNode
	// Repo is owner/repo, a project, or organization/project.
	Repo string
	// Number is an issue's or a pull request's number; Key is a tracker's key (ENG-12, PROJ-3).
	Number int
	Key    string
}

// pr says the ref is a pull request (a merge request on GitLab).
func (r forgeRef) pr() bool { return r.Node.Kind == lineage.KindPR }

// forgeScope is what a forge's Sources found, kept by the forge in its own type. Key is its part
// of a list's cache key.
type forgeScope interface {
	Key() []any
	Empty() bool
}

// forgeFilter is a list's request, one struct for every forge in place of each one's SearchFilter.
type forgeFilter struct {
	PRs                                    bool
	State, Label, Assignee, Query, Feature string
	// Board is the project board the list is of, nil for none; each forge reads its own.
	Board *forgeBoard
}

// forgeChild is a plan's new child (its title, labels and level), or an issue that is there to
// add (Issue, as a person wrote it: #12, owner/repo#12, ENG-4 or a URL).
type forgeChild struct {
	Title  string
	Labels []string
	Level  string
	Issue  string
}

// forges is the registry: every forge that has moved onto Forge, in a fixed order.
func (d *Daemon) forges() []Forge {
	return []Forge{githubForge{d: d}, gitlabForge{d: d}, forgejoForge{d: d}, bitbucketForge{d: d}, azureDevOpsForge{d: d},
		linearForge{d: d}, jiraForge{d: d}, azureBoardsForge{d: d}}
}

// forgeOwning is the forge that owns node, and its ref there.
func (d *Daemon) forgeOwning(node wire.LineageNode) (Forge, forgeRef, bool) {
	for _, f := range d.forges() {
		if r, ok := f.Owns(node); ok {
			return f, r, true
		}
	}
	return nil, forgeRef{}, false
}

// itemMethod is the read method of a kind of item: forge/issue or forge/pull.
func itemMethod(kind string) string {
	return "forge/" + map[string]string{lineage.KindIssue: "issue", lineage.KindPR: "pull"}[kind]
}
