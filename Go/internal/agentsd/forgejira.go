package agentsd

import (
	"context"
	"errors"
	"slices"
	"strings"

	"github.com/alexec/agents/Go/internal/jiramcp"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// jiraNoPRs is why a Jira issue has no merge, approval, run or diff: Jira has no pull requests.
const jiraNoPRs = "Jira has issues only: a pull request is on its repository's forge"

// jiraPlanHere is why a Jira plan has no new child and no blocked-by here.
const jiraPlanHere = "a Jira plan is changed in Jira, not yet here"

// jiraForge is Jira on the forge interface (#4329, #4358): the issues of the projects the
// folders' .agents/folder.json name in "jiraProjects", with the jira connector's sign-in, through
// forgeJira. An issue closes, reopens or moves by a transition of its workflow. Its plan is read
// here and changed in Jira. Its Caps say it has no pull requests. A node is jira:PROJ-12.
type jiraForge struct {
	forgeNone
	d *Daemon
}

func (jiraForge) Name() string { return "jira" }

func (jiraForge) Caps() forgeCaps {
	return forgeCaps{
		Issues:       true,
		Issue:        forgeActions{Comment: true, Label: true, Close: true, Reopen: true, Transition: true},
		CommentCount: "exact",
		Plan:         true,
		Reasons: map[string]string{
			actionMerge:     jiraNoPRs,
			actionAutoMerge: jiraNoPRs,
			actionApprove:   jiraNoPRs,
			actionRerun:     jiraNoPRs,
			actionLog:       jiraNoPRs,
			actionDiff:      jiraNoPRs,
			actionAddChild:  jiraPlanHere,
			actionBlockedBy: jiraPlanHere,
		},
	}
}

// Owns is jira:PROJ-12, an issue.
func (jiraForge) Owns(node wire.LineageNode) (forgeRef, bool) {
	key, ok := strings.CutPrefix(node.Ref, "jira:")
	if !ok || node.Kind != lineage.KindIssue || !linearLabel.MatchString(key) {
		return forgeRef{}, false
	}
	return forgeRef{Node: node, Key: key}, true
}

// jiraScope is what an issues list reads of Jira: the projects the folders name, each with the
// first folder that names it.
type jiraScope struct {
	issues        bool
	projects      []string
	projectFolder map[string]string
}

func (s jiraScope) Key() []any { return []any{s.projects} }

// Empty is true for a pull requests list only: a board's list is of a filter that no folder may
// name, so an issues list always asks List, which reads Jira only when there is a project or a
// board.
func (s jiraScope) Empty() bool { return !s.issues }

// Sources is the Jira projects of the folders, each once.
func (j jiraForge) Sources(_ context.Context, folders []string, prs bool) (forgeScope, error) {
	s := jiraScope{issues: !prs, projectFolder: map[string]string{}}
	if prs {
		return s, nil
	}
	for _, f := range folders {
		for _, project := range j.d.folderJiraProjects(f) {
			if _, seen := s.projectFolder[project]; !seen {
				s.projectFolder[project] = f
				s.projects = append(s.projects, project)
			}
		}
	}
	slices.Sort(s.projects)
	return s, nil
}

// List is one search for every project. A board's list is of its filter (#3282), in place of the
// projects: an issue of a project that no folder names acts from the board's first folder.
func (j jiraForge) List(ctx context.Context, scope forgeScope, f forgeFilter, cursor string, limit int) (forgePage, error) {
	s, _ := scope.(jiraScope)
	if f.PRs {
		return forgePage{}, nil
	}
	projects, home := s.projects, ""
	if b := f.Board; b != nil {
		if b.jira == "" {
			return forgePage{}, nil
		}
		projects, home = nil, b.home
	}
	if len(projects) == 0 && f.Board == nil {
		return forgePage{}, nil
	}
	jr, err := j.d.forgeJira()
	if err != nil {
		return forgePage{}, err
	}
	sf := jiramcp.SearchFilter{State: f.State, Label: f.Label, Assignee: f.Assignee, Query: f.Query, Feature: f.Feature}
	if f.Board != nil {
		if sf.Filter, err = jr.BoardFilter(ctx, f.Board.jira); err != nil {
			return forgePage{}, err
		}
	}
	page, err := jr.Search(ctx, projects, sf, cursor, limit)
	var p forgePage
	for _, i := range page.Items {
		folder, named := s.projectFolder[i.Project]
		if !named {
			folder = home
		}
		p.items = append(p.items, jiraItemOf(i, folder))
	}
	p.cursors, p.next = page.Cursors, page.Next
	return p, err
}

// jiraNotFound is err as a method's answer: an issue Jira does not have is Invalid.
func jiraNotFound(method string, err error) error {
	var je *jiramcp.JiraError
	if errors.As(err, &je) && je.Kind == jiramcp.NotFound {
		return Invalid("%s: %v", method, err)
	}
	return err
}

// Item is the issue with its body, a page of its comments and the transitions of its workflow.
func (j jiraForge) Item(ctx context.Context, r forgeRef, cursor string) (wire.ForgeItemDetail, error) {
	method := itemMethod(r.Node.Kind)
	jr, err := j.d.forgeJira()
	if err != nil {
		return wire.ForgeItemDetail{}, err
	}
	p, err := jr.ItemPage(ctx, r.Key, cursor)
	if err != nil {
		return wire.ForgeItemDetail{}, jiraNotFound(method, err)
	}
	out := wire.ForgeItemDetail{Item: jiraItemOf(p.Item, j.d.jiraFolder(p.Project)), Body: p.Body, Comments: []wire.ForgeComment{},
		Cursor: optional(p.Before), Transitions: []wire.ForgeTransition{}}
	out.Start = forgeStartOf(out.Item)
	for _, c := range p.Thread {
		out.Comments = append(out.Comments, forgeCommentOf(c.Author, c.Body, c.At, c.URL, c.Bot))
	}
	for _, t := range p.Transitions {
		out.Transitions = append(out.Transitions, wire.ForgeTransition{ID: t.ID, Name: t.Name, Category: optional(t.Category)})
	}
	return out, nil
}

// Labels are the labels in use on the site; Jira's labels have no colour.
func (j jiraForge) Labels(ctx context.Context, r forgeRef) ([]wire.ForgeLabel, error) {
	jr, err := j.d.forgeJira()
	if err != nil {
		return nil, err
	}
	names, colors, err := jr.Labels(ctx, r.Key)
	if err != nil {
		return nil, err
	}
	return forgeLabelsOf(names, colors), nil
}

// Plan is a Jira epic or parent and its children (#3260), each blocked by the issues its Blocks
// links say.
func (j jiraForge) Plan(ctx context.Context, r forgeRef) (forgePlanAnswer, error) {
	jr, err := j.d.forgeJira()
	if err != nil {
		return forgePlanAnswer{}, err
	}
	p, err := jr.Plan(ctx, r.Key)
	if err != nil {
		return forgePlanAnswer{}, jiraNotFound("forge/plan", err)
	}
	out := forgePlanAnswer{epic: jiraItemOf(p.Epic, j.d.jiraFolder(p.Epic.Project))}
	for _, c := range p.Children {
		pc := planChild{item: jiraItemOf(c.Item, j.d.jiraFolder(c.Project))}
		for _, b := range c.BlockedBy {
			pc.blockedBy = append(pc.blockedBy, planRef{node: jiraNode(b.Key), open: b.Open})
		}
		out.children = append(out.children, pc)
	}
	return out, nil
}

// Blockers is one read for every child (#4242). Jira says each key in upper case.
func (j jiraForge) Blockers(ctx context.Context, children []forgeRef) (map[forgeRef][]planRef, error) {
	jr, err := j.d.forgeJira()
	if err != nil {
		return nil, err
	}
	keys := make([]string, len(children))
	for n, c := range children {
		keys[n] = c.Key
	}
	by, err := jr.Blockers(ctx, keys)
	if err != nil {
		return nil, err
	}
	out := map[forgeRef][]planRef{}
	for _, c := range children {
		for _, b := range by[strings.ToUpper(c.Key)] {
			out[c] = append(out[c], planRef{node: jiraNode(b.Key), open: b.Open})
		}
	}
	return out, nil
}

func (j jiraForge) Comment(ctx context.Context, r forgeRef, body string) (wire.ForgeDone, error) {
	jr, err := j.d.forgeJira()
	if err != nil {
		return wire.ForgeDone{}, err
	}
	link, err := jr.Comment(ctx, r.Key, body)
	return wire.ForgeDone{URL: optional(link)}, err
}

func (j jiraForge) SetLabels(ctx context.Context, r forgeRef, add, remove []string) error {
	jr, err := j.d.forgeJira()
	if err != nil {
		return err
	}
	return jr.SetLabels(ctx, r.Key, add, remove)
}

// SetState moves the issue by the transition the page chose, or closes or reopens it by its
// workflow's own transitions.
func (j jiraForge) SetState(ctx context.Context, r forgeRef, closed bool, transition string) error {
	jr, err := j.d.forgeJira()
	if err != nil {
		return err
	}
	if transition != "" {
		return jr.Transition(ctx, r.Key, transition)
	}
	return jr.SetState(ctx, r.Key, closed)
}

// jiraNode is a Jira issue's node.
func jiraNode(key string) wire.LineageNode {
	return wire.LineageNode{Kind: lineage.KindIssue, Ref: "jira:" + key}
}
