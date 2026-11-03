package agentsd

import (
	"context"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// The plan's writes (#3271): a person changes an epic's plan from its page. Add child adds a new
// issue, or one that is there, as a sub-issue of the epic; Blocked by sets which issues a child
// waits for. They are the forge's own sub-issues and links (GitHub's sub-issue and dependency
// APIs, Linear's parent and "blocks" relations), so the plan forge/plan reads next is the
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
	case t.jira != nil:
		return forgeTarget{}, Invalid("%s: a Jira plan is changed in Jira, not yet here", method)
	case t.gitlab != nil:
		return forgeTarget{}, Invalid("%s: a GitLab plan is changed on GitLab, not yet here", method)
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
	if t.linear != nil {
		_, url, err = t.linear.AddChild(ctx, t.identifier, title, labels)
	} else {
		var n int
		if n, url, err = t.github.CreateIssue(ctx, t.repo.path, title, labels); err == nil {
			err = t.github.AddSubIssue(ctx, t.repo.path, t.number, t.repo.path, n)
		}
	}
	// A new issue that did not become a child is still made: forget the kept answers either way.
	d.forgeWrote()
	if err != nil {
		return wire.ForgeDone{}, err
	}
	return wire.ForgeDone{URL: optional(url)}, nil
}

// addExistingChild moves the issue that ref names under the epic t.
func (d *Daemon) addExistingChild(ctx context.Context, method string, t forgeTarget, epic wire.LineageNode, ref string) (wire.ForgeDone, error) {
	var err error
	if t.linear != nil {
		m := linearIssueRef.FindStringSubmatch(ref)
		if m == nil {
			return wire.ForgeDone{}, Invalid("%s: %q is not a Linear issue: give its key, such as ENG-4", method, ref)
		}
		key := strings.ToUpper(m[1])
		if key == t.identifier {
			return wire.ForgeDone{}, Invalid("%s: an epic is not its own child", method)
		}
		err = t.linear.SetParent(ctx, key, t.identifier)
	} else {
		m := githubIssueRef.FindStringSubmatch(ref)
		if m == nil {
			return wire.ForgeDone{}, Invalid("%s: %q is not a GitHub issue: give #12, owner/repo#12 or its URL", method, ref)
		}
		repo := strings.ToLower(m[1] + m[2])
		if repo == "" {
			repo = t.repo.path
		}
		n, _ := strconv.Atoi(m[3])
		if (forgeRepo{"github", repo}).issue(n) == epic {
			return wire.ForgeDone{}, Invalid("%s: an epic is not its own child", method)
		}
		err = t.github.AddSubIssue(ctx, t.repo.path, t.number, repo, n)
	}
	if err != nil {
		return wire.ForgeDone{}, err
	}
	d.forgeWrote()
	return wire.ForgeDone{}, nil
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
	// Every blocker is checked before the first write, so a wrong one changes nothing.
	type blocker struct {
		repo    string
		number  int
		key     string
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
			key, onLinear := strings.CutPrefix(b.Ref, "linear:")
			repo, n, onRepo := nodeOfRepo(b)
			switch {
			case b.Kind != lineage.KindIssue:
				return wire.ForgeDone{}, Invalid("%s: %s is not an issue", method, b.Ref)
			case t.linear != nil && onLinear && linearLabel.MatchString(key):
				todo = append(todo, blocker{key: key, blocked: list.blocked})
			case t.github != nil && onRepo && repo.forge == "github":
				todo = append(todo, blocker{repo: repo.path, number: n, blocked: list.blocked})
			default:
				return wire.ForgeDone{}, Invalid("%s: %s is not on the forge %s is on", method, b.Ref, r.Node.Ref)
			}
		}
	}
	for _, b := range todo {
		if t.linear != nil {
			err = t.linear.SetBlockedBy(ctx, t.identifier, b.key, b.blocked)
		} else {
			err = t.github.SetBlockedBy(ctx, t.repo.path, t.number, b.repo, b.number, b.blocked)
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
