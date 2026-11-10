package agentsd

import (
	"cmp"
	"context"
	"fmt"
	"slices"
	"strconv"
	"strings"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// Standing epics (#3659, #3661): an epic labelled standing as well as epic has a query, not
// sub-issues, as its plan, and never closes (the bug lane, the lane for enhancements with no parent). The query is a
// fenced standing block in the epic's body (specs/3659-standing-epics/spec.md); forge/plan
// returns its open issues in order, as one step.

// standingLabel makes an epic a standing one.
const standingLabel = "standing"

// standingPages is how many pages of forgeListMost a standing plan reads before it orders them,
// so a query whose first label is a common one still costs a bounded read.
const standingPages = 5

// standingFields are the fields a standing block can say.
var standingFields = []string{"labels", "any", "not", "milestone", "parent", "lanes"}

// standingQuery is a standing block as read: the wire's query, and parent: none (#4335), which
// takes only issues that are no other issue's sub-issue. The wire does not say parent yet.
type standingQuery struct {
	wire.ForgeStanding
	noParent bool
}

// standingOf reads the standing block in an epic's body. A body with no block, a second block,
// or an unknown or bad field gives a query with Error set.
func standingOf(body string) standingQuery {
	out := standingQuery{ForgeStanding: wire.ForgeStanding{Labels: []string{}, Any: []string{}, Not: []string{}, Lanes: 1}}
	fail := func(format string, a ...any) standingQuery {
		return standingQuery{ForgeStanding: wire.ForgeStanding{Labels: []string{}, Any: []string{}, Not: []string{}, Lanes: 1,
			Error: new(fmt.Sprintf(format, a...))}}
	}
	var block []string
	blocks, in := 0, false
	for _, line := range strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n") {
		t := strings.TrimSpace(line)
		switch {
		case in && strings.HasPrefix(t, "```"):
			in = false
		case in:
			block = append(block, t)
		case strings.HasPrefix(t, "```") && strings.EqualFold(strings.TrimSpace(t[3:]), standingLabel):
			blocks++
			in = true
		}
	}
	switch {
	case blocks == 0:
		return fail("the epic is labelled standing but its body has no standing block")
	case blocks > 1:
		return fail("the epic's body has %d standing blocks; it has one", blocks)
	}
	seen := map[string]bool{}
	for _, line := range block {
		if line == "" {
			continue
		}
		key, value, ok := strings.Cut(line, ":")
		key, value = strings.ToLower(strings.TrimSpace(key)), strings.TrimSpace(value)
		if !ok {
			return fail("the standing block's line %q is not field: value", line)
		}
		if !slices.Contains(standingFields, key) {
			return fail("the standing block has an unknown field %q; the fields are %s", key, strings.Join(standingFields, ", "))
		}
		if seen[key] {
			return fail("the standing block says %s twice", key)
		}
		seen[key] = true
		switch key {
		case "labels":
			out.Labels = standingList(value)
		case "any":
			out.Any = standingList(value)
		case "not":
			out.Not = standingList(value)
		case "milestone":
			if value == "" {
				return fail("the standing block's milestone is empty; it is none, any or a milestone's name")
			}
			if strings.EqualFold(value, "none") || strings.EqualFold(value, "any") {
				value = strings.ToLower(value)
			}
			out.Milestone = &value
		case "parent":
			if !strings.EqualFold(value, "none") {
				return fail("the standing block's parent is %q; it is none", value)
			}
			out.noParent = true
		case "lanes":
			n, err := strconv.Atoi(value)
			if err != nil || n < 1 {
				return fail("the standing block's lanes is %q; it is 1 or more", value)
			}
			out.Lanes = int64(n)
		}
	}
	return out
}

// standingList is a comma-separated list, each trimmed, with no empty ones.
func standingList(s string) []string {
	out := []string{}
	for v := range strings.SplitSeq(s, ",") {
		if v = strings.TrimSpace(v); v != "" {
			out = append(out, v)
		}
	}
	return out
}

// standingMatches says the query takes i: an open issue that is not an epic, with the query's
// labels and milestone. parent: none is said by standingParentless, as GitLab's and Forgejo's
// lists do not read an issue's parent.
func standingMatches(q standingQuery, i wire.ForgeItem) bool {
	if i.Node.Kind != lineage.KindIssue || i.State != "open" || deref(i.Level) == "epic" || hasLabel(i, "epic") {
		return false
	}
	for _, l := range q.Labels {
		if !hasLabel(i, l) {
			return false
		}
	}
	if len(q.Any) > 0 && !slices.ContainsFunc(q.Any, func(l string) bool { return hasLabel(i, l) }) {
		return false
	}
	if slices.ContainsFunc(q.Not, func(l string) bool { return hasLabel(i, l) }) {
		return false
	}
	switch m := deref(q.Milestone); m {
	case "":
		return true
	case "none":
		return deref(i.Milestone) == ""
	case "any":
		return deref(i.Milestone) != ""
	default:
		return strings.EqualFold(deref(i.Milestone), m)
	}
}

func hasLabel(i wire.ForgeItem, name string) bool {
	return slices.ContainsFunc(i.Labels, func(l wire.ForgeLabel) bool { return strings.EqualFold(strings.TrimSpace(l.Name), name) })
}

// standingRank is an issue's priority from its labels: high, medium, none, then low.
func standingRank(i wire.ForgeItem) int {
	switch {
	case hasLabel(i, "priority:high"):
		return 0
	case hasLabel(i, "priority:medium"):
		return 1
	case hasLabel(i, "priority:low"):
		return 3
	}
	return 2
}

// refSource and refNumber split a node's ref into its repo, team or project and its number:
// github:a/b#12 is github:a/b# and 12, linear:ENG-7 is linear:ENG- and 7.
func refSource(ref string) string {
	return strings.ToLower(strings.TrimRight(ref, "0123456789"))
}

func refNumber(ref string) int {
	n, _ := strconv.Atoi(ref[len(strings.TrimRight(ref, "0123456789")):])
	return n
}

// standingOrder puts a standing plan's issues in order: priority first, then the oldest (the
// lowest number), so no issue waits for ever behind newer ones of the same priority.
func standingOrder(items []wire.ForgeItem) {
	slices.SortStableFunc(items, func(a, b wire.ForgeItem) int {
		return cmp.Or(cmp.Compare(standingRank(a), standingRank(b)), cmp.Compare(refNumber(a.Node.Ref), refNumber(b.Node.Ref)),
			cmp.Compare(a.Node.Ref, b.Node.Ref))
	})
}

// standingPlan is a standing epic's query, read from its body, and the open issues of its repo
// (or Linear team, or Jira project) that it takes, in order, at most forgeListMost. The list is
// read with forge/issues on the epic's folder, narrowed on the forge by the query's first label,
// and the rest of the query is said here, so every forge reads it the same way.
func (d *Daemon) standingPlan(ctx context.Context, method string, epic wire.ForgeItem) (wire.ForgeStanding, []planChild, error) {
	detail, err := d.forgeItem(ctx, lineage.KindIssue, wire.ForgeItemRequest{Node: epic.Node})
	if err != nil {
		return wire.ForgeStanding{}, nil, err
	}
	q := standingOf(detail.Body)
	if q.Error != nil {
		return q.ForgeStanding, nil, nil
	}
	if deref(epic.Folder) == "" {
		q.Error = new("no folder on this machine is on the epic's repo")
		return q.ForgeStanding, nil, nil
	}
	list := wire.ForgeListRequest{Folder: epic.Folder, State: new("open"), Limit: new(int64(forgeListMost))}
	if len(q.Labels) > 0 {
		list.Label = &q.Labels[0]
	}
	source := refSource(epic.Node.Ref)
	var items []wire.ForgeItem
	for range standingPages {
		page, err := d.forgeList(ctx, false, list)
		if err != nil {
			return wire.ForgeStanding{}, nil, Invalid("%s: %v", method, strings.TrimPrefix(err.Error(), "forge/issues: "))
		}
		for _, i := range page.Items {
			if refSource(i.Node.Ref) == source && i.Node != epic.Node && standingMatches(q, i) {
				items = append(items, i)
			}
		}
		if page.Cursor == nil {
			break
		}
		list.Cursor = page.Cursor
	}
	standingOrder(items)
	if q.noParent {
		if items, err = d.standingParentless(ctx, method, epic, items); err != nil {
			return wire.ForgeStanding{}, nil, err
		}
	}
	children := []planChild{}
	for _, i := range items[:min(len(items), forgeListMost)] {
		children = append(children, planChild{item: i})
	}
	if err := d.standingBlockers(ctx, method, epic, children); err != nil {
		return wire.ForgeStanding{}, nil, err
	}
	return q.ForgeStanding, children, nil
}

// standingParentsMost is how many issues one read of their parents asks about, as GitLab's and
// Forgejo's BlockersMost.
const standingParentsMost = 100

// standingParentless keeps the items, in order, that are no issue's sub-issue (#4335), at most
// forgeListMost. GitHub's, Linear's, Jira's and Azure Boards' lists say each issue's parent;
// GitLab's and Forgejo's do not, so their parents are read a page at a time, only until
// forgeListMost are kept.
func (d *Daemon) standingParentless(ctx context.Context, method string, epic wire.ForgeItem, items []wire.ForgeItem) ([]wire.ForgeItem, error) {
	out := []wire.ForgeItem{}
	for len(items) > 0 && len(out) < forgeListMost {
		page := items[:min(len(items), standingParentsMost)]
		items = items[len(page):]
		if err := d.standingParents(ctx, method, epic, page); err != nil {
			return nil, err
		}
		for _, i := range page {
			if i.Parent == nil {
				out = append(out, i)
			}
		}
	}
	return out[:min(len(out), forgeListMost)], nil
}

// standingParents sets the parent of each of items on GitLab and Forgejo, whose lists do not
// read it: one GraphQL query on GitLab, and on Forgejo a call for each, for the epic that
// depends on it. The items are on the epic's own repo or project.
func (d *Daemon) standingParents(ctx context.Context, method string, epic wire.ForgeItem, items []wire.ForgeItem) error {
	numbers := make([]int, len(items))
	for n, i := range items {
		numbers[n] = refNumber(i.Node.Ref)
	}
	if repo, _, ok := forgejoOfNode(epic.Node); ok {
		fj, named, _, err := d.forgejoOf(ctx, method, repo)
		if err != nil {
			return err
		}
		parents, err := fj.Parents(ctx, named, numbers)
		if err != nil {
			return err
		}
		for n := range items {
			if p, ok := parents[numbers[n]]; ok {
				items[n].Parent = new(forgejoNode(p.Repo, p.Number, false))
			}
		}
		return nil
	}
	repo, _, ok := nodeOfRepo(epic.Node)
	if !ok || repo.forge != "gitlab" {
		return nil
	}
	gl, project, _, err := d.gitlabOf(ctx, method, repo)
	if err != nil {
		return err
	}
	parents, err := gl.Parents(ctx, project, numbers)
	if err != nil {
		return err
	}
	for n := range items {
		if p, ok := parents[numbers[n]]; ok {
			items[n].Parent = new(forgeRepo{"gitlab", strings.ToLower(p.Project)}.issue(p.Number))
		}
	}
	return nil
}

// standingBlockers sets the blockers of a standing epic's children, which a list does not read:
// one read for all of them on each forge (#4200, #4242). The children are on the epic's own repo,
// project or team, so they are read where the epic is. Forgejo reads a child's at a time.
func (d *Daemon) standingBlockers(ctx context.Context, method string, epic wire.ForgeItem, children []planChild) error {
	if len(children) == 0 {
		return nil
	}
	set := func(n int, node wire.LineageNode, open bool) {
		children[n].blockedBy = append(children[n].blockedBy, planRef{node: node, open: open})
	}
	numbers := make([]int, len(children))
	for n, c := range children {
		numbers[n] = refNumber(c.item.Node.Ref)
	}
	if f, _, ok := d.forgeOwning(epic.Node); ok {
		refs := make([]forgeRef, len(children))
		for n, c := range children {
			if refs[n], ok = f.Owns(c.item.Node); !ok {
				return Invalid("%s: %s is not on the forge %s is on", method, c.item.Node.Ref, epic.Node.Ref)
			}
		}
		by, err := f.Blockers(ctx, refs)
		if err != nil {
			return forgeCannotErr(method, f, err)
		}
		for n := range children {
			children[n].blockedBy = append(children[n].blockedBy, by[refs[n]]...)
		}
		return nil
	}
	keys := make([]string, len(children))
	for n, c := range children {
		_, keys[n], _ = strings.Cut(c.item.Node.Ref, ":")
	}
	switch {
	case strings.HasPrefix(epic.Node.Ref, "linear:"):
		l, err := d.forgeLinear()
		if err != nil {
			return err
		}
		by, err := l.Blockers(ctx, keys)
		if err != nil {
			return err
		}
		for n := range children {
			for _, b := range by[keys[n]] {
				set(n, wire.LineageNode{Kind: lineage.KindIssue, Ref: "linear:" + b.Identifier}, b.Open)
			}
		}
	case strings.HasPrefix(epic.Node.Ref, "jira:"):
		j, err := d.forgeJira()
		if err != nil {
			return err
		}
		by, err := j.Blockers(ctx, keys)
		if err != nil {
			return err
		}
		for n := range children {
			for _, b := range by[strings.ToUpper(keys[n])] {
				set(n, wire.LineageNode{Kind: lineage.KindIssue, Ref: "jira:" + b.Key}, b.Open)
			}
		}
	default:
		if project, _, ok := boardsOfNode(epic.Node); ok {
			b, err := d.forgeAzureBoards()
			if err != nil {
				return err
			}
			by, err := b.Blockers(ctx, project, numbers)
			if err != nil {
				return err
			}
			for n := range children {
				for _, r := range by[numbers[n]] {
					set(n, boardsNode(r.Project, r.ID), r.Open)
				}
			}
			return nil
		}
	}
	return nil
}
