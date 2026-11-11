package agentsd

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/internal/linearmcp"
	"github.com/alexec/agents/Go/wire"
)

// linearNoPRs is why a Linear issue has no merge, approval, run or diff: Linear has no pull
// requests.
const linearNoPRs = "Linear has issues only: a pull request is on its repository's forge"

// linearForge is Linear on the forge interface (#4329, #4357): the issues of the teams the
// folders' .agents/folder.json name in "linearTeams", or of the whole workspace when no folder
// names one (#3311), with the Linear connection, through forgeLinear. Its Caps say it has no pull
// requests. A node is linear:ENG-12.
type linearForge struct {
	forgeNone
	d *Daemon
}

func (linearForge) Name() string { return "linear" }

func (linearForge) Caps() forgeCaps {
	return forgeCaps{
		Issues:      true,
		Issue:       forgeActions{Comment: true, Label: true, Close: true, Reopen: true},
		LabelColors: true,
		Avatars:     true,
		StateReason: true,
		// Linear does not count an issue's comments: a list reads at most 50.
		CommentCount: "capped", CommentsMost: 50,
		Plan: true, BlockedBy: true, AddChild: true,
		Reasons: map[string]string{
			actionTransition: "only a Jira issue or an Azure Boards work item moves by a transition",
			actionMerge:      linearNoPRs,
			actionAutoMerge:  linearNoPRs,
			actionApprove:    linearNoPRs,
			actionRerun:      linearNoPRs,
			actionLog:        linearNoPRs,
			actionDiff:       linearNoPRs,
		},
	}
}

// Owns is linear:ENG-12, an issue.
func (linearForge) Owns(node wire.LineageNode) (forgeRef, bool) {
	identifier, ok := strings.CutPrefix(node.Ref, "linear:")
	if !ok || node.Kind != lineage.KindIssue || !linearLabel.MatchString(identifier) {
		return forgeRef{}, false
	}
	return forgeRef{Node: node, Key: identifier}, true
}

// linearScope is what an issues list reads of Linear: the teams the folders name, each with the
// first folder that names it; or, when no folder here names one, the whole workspace, whose
// issues act from home.
type linearScope struct {
	issues     bool
	teams      []string
	teamFolder map[string]string
	workspace  bool
	home       string
}

func (s linearScope) Key() []any { return []any{s.teams, s.workspace, s.home} }

// Empty is true for a pull requests list only: a board's list is of a team that no folder may
// name, so an issues list always asks List, which reads Linear only when there is a team.
func (s linearScope) Empty() bool { return !s.issues }

// Sources is the Linear teams of the folders, each once. With none, and no folder here naming
// any, it is the whole workspace when Linear is connected: most people have no Linear, so a list
// without the connection leaves Linear out, with no error.
func (l linearForge) Sources(_ context.Context, folders []string, prs bool) (forgeScope, error) {
	s := linearScope{issues: !prs, teamFolder: map[string]string{}}
	if prs {
		return s, nil
	}
	for _, f := range folders {
		for _, team := range l.d.folderLinearTeams(f) {
			if _, seen := s.teamFolder[team]; !seen {
				s.teamFolder[team] = f
				s.teams = append(s.teams, team)
			}
		}
	}
	slices.Sort(s.teams)
	if len(s.teams) == 0 && l.d.linearConnected() && !l.d.anyLinearTeams() {
		s.workspace, s.home = true, l.d.linearHome()
	}
	return s, nil
}

// List is one query for every team. A board's list is of its team: an issue of a team that no
// folder names acts from the board's first folder.
func (l linearForge) List(ctx context.Context, scope forgeScope, f forgeFilter, cursor string, limit int) (forgePage, error) {
	s, _ := scope.(linearScope)
	if f.PRs {
		return forgePage{}, nil
	}
	teams, workspace, home := s.teams, s.workspace, s.home
	if b := f.Board; b != nil {
		teams, workspace = []string{b.linear}, false
		if _, named := s.teamFolder[b.linear]; !named {
			home = b.home
		}
	}
	if len(teams) == 0 && !workspace {
		return forgePage{}, nil
	}
	ln, err := l.d.forgeLinear()
	if err != nil {
		return forgePage{}, err
	}
	page, err := ln.Search(ctx, teams, linearmcp.SearchFilter{State: f.State, Label: f.Label, Assignee: f.Assignee, Query: f.Query,
		Feature: f.Feature}, cursor, limit)
	var p forgePage
	for _, i := range page.Items {
		folder, named := s.teamFolder[i.Team]
		if !named {
			folder = home
		}
		p.items = append(p.items, linearItemOf(i, folder))
	}
	p.cursors, p.next = page.Cursors, page.Next
	return p, err
}

// linearNotFound is err as a method's answer: an issue Linear does not have is Invalid.
func linearNotFound(method string, err error) error {
	var le *linearmcp.LinearError
	if errors.As(err, &le) && le.Kind == linearmcp.NotFound {
		return Invalid("%s: %v", method, err)
	}
	return err
}

func (l linearForge) Item(ctx context.Context, r forgeRef, cursor string) (wire.ForgeItemDetail, error) {
	method := itemMethod(r.Node.Kind)
	ln, err := l.d.forgeLinear()
	if err != nil {
		return wire.ForgeItemDetail{}, err
	}
	p, err := ln.ItemPage(ctx, r.Key, cursor)
	if err != nil {
		return wire.ForgeItemDetail{}, linearNotFound(method, err)
	}
	out := wire.ForgeItemDetail{Item: linearItemOf(p.Item, l.d.linearFolder(p.Team)), Body: p.Body, Comments: []wire.ForgeComment{}, Cursor: optional(p.Before)}
	out.Start = linearStart(out.Item)
	for _, c := range p.Thread {
		out.Comments = append(out.Comments, forgeCommentOf(c.Author, c.Avatar, c.Body, c.At, c.URL, c.Bot))
	}
	return out, nil
}

// Labels are the labels of the issue's team and workspace, with their colours.
func (l linearForge) Labels(ctx context.Context, r forgeRef) ([]wire.ForgeLabel, error) {
	ln, err := l.d.forgeLinear()
	if err != nil {
		return nil, err
	}
	names, colors, err := ln.Labels(ctx, r.Key)
	if err != nil {
		return nil, err
	}
	return forgeLabelsOf(names, colors), nil
}

// Plan is a Linear epic and its sub-issues, each blocked by the issues that block it.
func (l linearForge) Plan(ctx context.Context, r forgeRef) (forgePlanAnswer, error) {
	ln, err := l.d.forgeLinear()
	if err != nil {
		return forgePlanAnswer{}, err
	}
	p, err := ln.Plan(ctx, r.Key)
	if err != nil {
		return forgePlanAnswer{}, linearNotFound("forge/plan", err)
	}
	out := forgePlanAnswer{epic: linearItemOf(p.Epic, l.d.linearFolder(p.Epic.Team))}
	for _, c := range p.Children {
		pc := planChild{item: linearItemOf(c.Item, l.d.linearFolder(c.Team))}
		for _, b := range c.BlockedBy {
			pc.blockedBy = append(pc.blockedBy, planRef{node: linearNode(b.Identifier), open: b.Open})
		}
		out.children = append(out.children, pc)
	}
	return out, nil
}

// Blockers is one read for every child.
func (l linearForge) Blockers(ctx context.Context, children []forgeRef) (map[forgeRef][]planRef, error) {
	ln, err := l.d.forgeLinear()
	if err != nil {
		return nil, err
	}
	keys := make([]string, len(children))
	for n, c := range children {
		keys[n] = c.Key
	}
	by, err := ln.Blockers(ctx, keys)
	if err != nil {
		return nil, err
	}
	out := map[forgeRef][]planRef{}
	for _, c := range children {
		for _, b := range by[c.Key] {
			out[c] = append(out[c], planRef{node: linearNode(b.Identifier), open: b.Open})
		}
	}
	return out, nil
}

func (l linearForge) Comment(ctx context.Context, r forgeRef, body string) (wire.ForgeDone, error) {
	ln, err := l.d.forgeLinear()
	if err != nil {
		return wire.ForgeDone{}, err
	}
	link, err := ln.Comment(ctx, r.Key, body)
	return wire.ForgeDone{URL: optional(link)}, err
}

func (l linearForge) SetLabels(ctx context.Context, r forgeRef, add, remove []string) error {
	ln, err := l.d.forgeLinear()
	if err != nil {
		return err
	}
	return ln.SetLabels(ctx, r.Key, add, remove)
}

func (l linearForge) SetState(ctx context.Context, r forgeRef, closed bool, transition string) error {
	if transition != "" {
		return cannot(actionTransition)
	}
	ln, err := l.d.forgeLinear()
	if err != nil {
		return err
	}
	return ln.SetState(ctx, r.Key, closed)
}

// AddChild makes a new issue in the epic's team as its sub-issue, or makes the issue that
// child.Issue names (ENG-4, or its URL on linear.app) one.
func (l linearForge) AddChild(ctx context.Context, epic forgeRef, child forgeChild) (wire.ForgeDone, error) {
	const method = "forge/add-child"
	ln, err := l.d.forgeLinear()
	if err != nil {
		return wire.ForgeDone{}, err
	}
	if child.Issue == "" {
		_, link, err := ln.AddChild(ctx, epic.Key, child.Title, child.Labels)
		return wire.ForgeDone{URL: optional(link)}, err
	}
	m := linearIssueRef.FindStringSubmatch(child.Issue)
	if m == nil {
		return wire.ForgeDone{}, Invalid("%s: %q is not a Linear issue: give its key, such as ENG-4", method, child.Issue)
	}
	key := strings.ToUpper(m[1])
	if key == epic.Key {
		return wire.ForgeDone{}, Invalid("%s: an epic is not its own child", method)
	}
	return wire.ForgeDone{}, ln.SetParent(ctx, key, epic.Key)
}

func (l linearForge) SetBlockedBy(ctx context.Context, r, blocker forgeRef, blocked bool) error {
	ln, err := l.d.forgeLinear()
	if err != nil {
		return err
	}
	return ln.SetBlockedBy(ctx, r.Key, blocker.Key, blocked)
}

// linearNode is a Linear issue's node.
func linearNode(identifier string) wire.LineageNode {
	return wire.LineageNode{Kind: lineage.KindIssue, Ref: "linear:" + identifier}
}

// linearStart is the new-agent form for a Linear issue, labelled with its identifier (ENG-12).
func linearStart(i wire.ForgeItem) *wire.ForgeStart {
	identifier := strings.TrimPrefix(i.Node.Ref, "linear:")
	return &wire.ForgeStart{Prompt: fmt.Sprintf("%s: %s\n\nWork on this Linear issue: %s", identifier, i.Title, deref(i.URL)),
		Labels: []string{identifier}, Worktree: optional(identifier + " " + i.Title)}
}
