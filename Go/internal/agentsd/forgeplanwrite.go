package agentsd

import (
	"context"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/alexec/agents/Go/internal/forgejomcp"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// The plan's writes (#3271): a person changes an epic's plan from its page. Add child adds a new
// issue, or one that is there, as a sub-issue of the epic; Blocked by sets which issues a child
// waits for. They are the forge's own sub-issues and links (GitHub's sub-issue and dependency
// APIs, Linear's parent and "blocks" relations, Azure Boards' parent and predecessor links,
// #3815, and Forgejo's issue dependencies, #3835), so the plan forge/plan reads next is the
// forge's, as for every other reader. GitLab's links are Premium only and Jira's come later, so
// those two refuse, and say so. Like the other writes (forgewrite.go), only a person's window or
// device may call them.

const (
	// forgeTitleMost bounds a new child's title, as GitHub does.
	forgeTitleMost = 256
	// forgeBlockersMost bounds the blockers one call adds or takes off.
	forgeBlockersMost = 20
)

// childLevels are the levels a new child can have; "" is none.
var childLevels = []string{"", "story", "task", "spike", "bug"}

var (
	// githubIssueRef is #12, owner/repo#12 or an issue's URL on github.com.
	githubIssueRef = regexp.MustCompile(`^(?:https://github\.com/([\w.-]+/[\w.-]+)/issues/|([\w.-]+/[\w.-]+)?#)([0-9]{1,9})/?$`)
	// forgejoIssueRef is #12, owner/repo#12, or an issue's URL on a Forgejo (checked against the
	// connected one's root).
	forgejoIssueRef = regexp.MustCompile(`^(?:(https?://\S+/)([\w.-]+/[\w.-]+)/issues/|([\w.-]+/[\w.-]+)?#)([0-9]{1,9})/?$`)
	// linearIssueRef is ENG-4, or its URL on linear.app.
	linearIssueRef = regexp.MustCompile(`^(?:https://linear\.app/[\w.-]+/issue/)?([A-Za-z][A-Za-z0-9]{0,9}-[0-9]{1,9})(?:/[\w.-]*)?$`)
)

func (d *Daemon) registerForgePlanWrites() {
	On(d, wire.CallForgeAddChild, func(ctx context.Context, _ *Client, r wire.ForgeAddChildRequest) (wire.ForgeDone, error) {
		return d.forgeAddChild(ctx, r)
	})
	On(d, wire.CallForgeBlockedBy, func(ctx context.Context, _ *Client, r wire.ForgeBlockedByRequest) (wire.ForgeDone, error) {
		return d.forgeBlockedBy(ctx, r)
	})
}

// planTargetOf is an issue's forge for a plan's write, or why it has none.
func (d *Daemon) planTargetOf(ctx context.Context, method string, node wire.LineageNode) (forgeTarget, error) {
	if node.Kind != lineage.KindIssue {
		return forgeTarget{}, Invalid("%s: %s is not an issue", method, node.Ref)
	}
	t, err := d.forgeTargetOf(ctx, method, node, false)
	if err != nil {
		return forgeTarget{}, err
	}
	switch {
	case t.forge != nil && !t.forge.Caps().Plan:
		return forgeTarget{}, forgeCannotErr(method, t.forge, cannot(actionPlan))
	case t.jira != nil:
		return forgeTarget{}, Invalid("%s: a Jira plan is changed in Jira, not yet here", method)
	}
	return t, nil
}

func (d *Daemon) forgeAddChild(ctx context.Context, r wire.ForgeAddChildRequest) (wire.ForgeDone, error) {
	const method = "forge/add-child"
	title, issue := strings.TrimSpace(deref(r.Title)), strings.TrimSpace(deref(r.Issue))
	level := strings.ToLower(strings.TrimSpace(deref(r.Level)))
	switch {
	case (title == "") == (issue == ""):
		return wire.ForgeDone{}, Invalid("%s: give a new child's title or an issue that is there, one of them", method)
	case len(title) > forgeTitleMost:
		return wire.ForgeDone{}, Invalid("%s: a title is at most %d bytes", method, forgeTitleMost)
	case !slices.Contains(childLevels, level):
		return wire.ForgeDone{}, Invalid("%s: a child's level is story, task, spike or bug, not %s", method, level)
	}
	t, err := d.planTargetOf(ctx, method, r.Node)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	// A forge that adds no child says so before the plan is read for the new child's labels.
	if t.forge != nil && !t.forge.Caps().AddChild {
		return wire.ForgeDone{}, forgeCannotErr(method, t.forge, cannot(actionAddChild))
	}
	if issue != "" && t.forge != nil {
		done, err := t.forge.AddChild(ctx, t.ref, forgeChild{Issue: issue})
		if err != nil {
			return wire.ForgeDone{}, forgeCannotErr(method, t.forge, err)
		}
		d.forgeWrote()
		return done, nil
	}
	if issue != "" {
		return d.addExistingChild(ctx, method, t, r.Node, issue)
	}
	// A new child is in the epic's feature (#3265): the epic's page has just read its plan, so this
	// read is the kept one.
	plan, err := d.forgePlan(ctx, wire.ForgePlanRequest{Node: r.Node})
	if err != nil {
		return wire.ForgeDone{}, err
	}
	labels := []string{}
	if level != "" {
		labels = append(labels, level)
	}
	if f := plan.Item.Feature; f != nil {
		labels = append(labels, featurePrefix+*f)
	}
	var url string
	if t.forge != nil {
		var done wire.ForgeDone
		done, err = t.forge.AddChild(ctx, t.ref, forgeChild{Title: title, Labels: labels, Level: level})
		url, err = deref(done.URL), forgeCannotErr(method, t.forge, err)
	} else if t.boards != nil {
		// The level is the work item's type too, as its process names it.
		_, url, err = t.boards.AddChild(ctx, t.project, t.number, title, labels, level)
	}
	// A new issue that did not become a child is still made: forget the kept answers either way.
	d.forgeWrote()
	if err != nil {
		return wire.ForgeDone{}, err
	}
	return wire.ForgeDone{URL: optional(url)}, nil
}

// addExistingChild moves the work item that ref names under the Azure Boards epic t.
func (d *Daemon) addExistingChild(ctx context.Context, method string, t forgeTarget, epic wire.LineageNode, ref string) (wire.ForgeDone, error) {
	id, ok := boardsItemID(ref)
	if !ok {
		return wire.ForgeDone{}, Invalid("%s: %q is not a work item: give its id, such as 12 or AB#12, or its page", method, ref)
	}
	if id == t.number {
		return wire.ForgeDone{}, Invalid("%s: an epic is not its own child", method)
	}
	if err := t.boards.SetParent(ctx, t.project, id, t.number); err != nil {
		return wire.ForgeDone{}, err
	}
	d.forgeWrote()
	return wire.ForgeDone{}, nil
}

// forgejoIssueOf is the repository and number ref names on the connected Forgejo: #12 is in
// repo, the epic's own; a URL must be on the connected Forgejo.
func (d *Daemon) forgejoIssueOf(ref, repo string) (string, int, bool) {
	m := forgejoIssueRef.FindStringSubmatch(ref)
	if m == nil {
		return "", 0, false
	}
	if m[1] != "" {
		if _, root := d.forgejoRoot(); root == "" || !strings.EqualFold(forgejomcp.BaseURL(m[1]), root) {
			return "", 0, false
		}
	}
	if named := m[2] + m[3]; named != "" {
		repo = named
	}
	n, _ := strconv.Atoi(m[4])
	return strings.ToLower(repo), n, true
}

func (d *Daemon) forgeBlockedBy(ctx context.Context, r wire.ForgeBlockedByRequest) (wire.ForgeDone, error) {
	const method = "forge/blocked-by"
	if len(r.Add)+len(r.Remove) == 0 {
		return wire.ForgeDone{}, Invalid("%s: name an issue to add or take off", method)
	}
	if len(r.Add) > forgeBlockersMost || len(r.Remove) > forgeBlockersMost {
		return wire.ForgeDone{}, Invalid("%s: at most %d blockers to change at once", method, forgeBlockersMost)
	}
	t, err := d.planTargetOf(ctx, method, r.Node)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	if t.forge != nil && !t.forge.Caps().BlockedBy {
		return wire.ForgeDone{}, forgeCannotErr(method, t.forge, cannot(actionBlockedBy))
	}
	// Every blocker is checked before the first write, so a wrong one changes nothing.
	type blocker struct {
		ref     forgeRef
		number  int
		blocked bool
	}
	var todo []blocker
	for _, list := range []struct {
		nodes   []wire.LineageNode
		blocked bool
	}{{r.Add, true}, {r.Remove, false}} {
		for _, b := range list.nodes {
			if b == r.Node {
				return wire.ForgeDone{}, Invalid("%s: an issue does not block itself", method)
			}
			project, id, onBoards := boardsOfNode(b)
			switch {
			case b.Kind != lineage.KindIssue:
				return wire.ForgeDone{}, Invalid("%s: %s is not an issue", method, b.Ref)
			case t.forge != nil:
				ref, ok := t.forge.Owns(b)
				if !ok {
					return wire.ForgeDone{}, Invalid("%s: %s is not on the forge %s is on", method, b.Ref, r.Node.Ref)
				}
				todo = append(todo, blocker{ref: ref, blocked: list.blocked})
			// A link is within an organization.
			case t.boards != nil && onBoards && boardsOrg(project) == boardsOrg(t.project):
				todo = append(todo, blocker{number: id, blocked: list.blocked})
			default:
				return wire.ForgeDone{}, Invalid("%s: %s is not on the forge %s is on", method, b.Ref, r.Node.Ref)
			}
		}
	}
	for _, b := range todo {
		if t.forge != nil {
			err = forgeCannotErr(method, t.forge, t.forge.SetBlockedBy(ctx, t.ref, b.ref, b.blocked))
		} else {
			err = t.boards.SetBlockedBy(ctx, t.project, t.number, b.number, b.blocked)
		}
		if err != nil {
			break
		}
	}
	// Some links may be written before one fails: forget the kept answers either way.
	d.forgeWrote()
	if err != nil {
		return wire.ForgeDone{}, err
	}
	return wire.ForgeDone{}, nil
}
