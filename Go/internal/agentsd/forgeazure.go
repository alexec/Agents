package agentsd

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/azureboardsmcp"
	"github.com/alexec/agents/Go/internal/azuredevopsmcp"
	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// Azure Boards on the Work pages (#3815, after Jira's #3260): the work items of the projects
// the folders' .agents/folder.json name in "azureBoardsProjects": ["organization/project"],
// read and written with the azuredevops and azureboards connectors' sign-in (AZURE_DEVOPS_TOKEN
// and AZURE_DEVOPS_URL in the secrets, else the Azure DevOps connection, #3802) through azureboardsmcp.RealBoards. A work item is the
// node azureboards:organization/project#12, in lower case; its state's name is its status, and
// its page moves it to another state of its type, as a Jira issue's moves by a transition. A
// session labelled AB#12, and a pull request whose title or branch says AB#12 (Azure Boards'
// own way to name a work item from a commit), link to the work item of the folder's first
// project.

// forgeAzureBoards is what the forge reads and writes ask of Azure Boards; a test gives a fake.
type forgeAzureBoards interface {
	Search(ctx context.Context, projects []string, f azureboardsmcp.SearchFilter, after string, first int) (azureboardsmcp.SearchPage, error)
	ItemPage(ctx context.Context, project string, id int, before string) (azureboardsmcp.ItemDetail, error)
	Comment(ctx context.Context, project string, id int, body string) (string, error)
	SetTags(ctx context.Context, project string, id int, add, remove []string) error
	Labels(ctx context.Context, project string, id int) ([]string, map[string]string, error)
	SetState(ctx context.Context, project string, id int, closed bool) error
	Transition(ctx context.Context, project string, id int, state string) error
	Plan(ctx context.Context, project string, id int) (azureboardsmcp.Plan, error)
	// Blockers are the predecessors of a standing epic's children (#4242).
	Blockers(ctx context.Context, project string, ids []int) (map[int][]azureboardsmcp.Ref, error)
	AddChild(ctx context.Context, project string, parent int, title string, labels []string, level string) (int, string, error)
	SetParent(ctx context.Context, project string, id, parent int) error
	SetBlockedBy(ctx context.Context, project string, id, blocker int, blocked bool) error
	TeamAreas(ctx context.Context, project, team string) ([]azureboardsmcp.Area, error)
}

var (
	// boardsProject is organization/project: an organization's name, and a project's, which may
	// hold spaces.
	boardsProject = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,49}/[^/#\\]{1,64}$`)
	// abLabel is a session's label for a work item: AB#12.
	abLabel = regexp.MustCompile(`^AB#([0-9]{1,9})$`)
	// abInText is AB#12 in a PR's title or branch, not inside a longer word.
	abInText = regexp.MustCompile(`(?i)\bAB#([0-9]{1,9})\b`)
	// boardsItemRef is 12, #12, AB#12 or a work item's page, …/_workitems/edit/12.
	boardsItemRef = regexp.MustCompile(`^(?:(?i:AB)?#)?([0-9]{1,9})$|/_workitems/edit/([0-9]{1,9})/?$`)
)

// boardsNode is the work item project#id.
func boardsNode(project string, id int) wire.LineageNode {
	return numbered(lineage.KindIssue, "azureboards", project, id)
}

// boardsOfNode is the project and id of a work item's node.
func boardsOfNode(n wire.LineageNode) (string, int, bool) {
	project, id, ok := numberedNode(n, "azureboards", lineage.KindIssue)
	if !ok || !boardsProject.MatchString(project) {
		return "", 0, false
	}
	return project, id, true
}

// boardsOrg is a project's organization.
func boardsOrg(project string) string {
	org, _, _ := strings.Cut(project, "/")
	return org
}

// folderBoardsProjects is the Azure Boards projects, organization/project in lower case, that
// a folder's .agents/folder.json names for its tasks: "azureBoardsProjects": ["acme/Web App"].
func (d *Daemon) folderBoardsProjects(folder string) []string {
	m, err := d.approvedConfig(folder)
	if err != nil {
		return nil
	}
	list, _ := m["azureBoardsProjects"].([]any)
	var out []string
	for _, v := range list {
		if p, ok := v.(string); ok {
			if p = strings.ToLower(strings.Trim(strings.TrimSpace(p), "/")); boardsProject.MatchString(p) && !slices.Contains(out, p) {
				out = append(out, p)
			}
		}
	}
	return out
}

// boardsFolder is the first folder whose .agents/folder.json names project, or "".
func (d *Daemon) boardsFolder(project string) string {
	for _, f := range d.folderPaths() {
		if slices.Contains(d.folderBoardsProjects(f), project) {
			return f
		}
	}
	return ""
}

// azureBoardsSignIn is the azuredevops connector's sign-in on this host (its secrets), else the
// Azure DevOps connection's (#3802): its token, "" for none, and the Azure DevOps it is for.
func (d *Daemon) azureBoardsSignIn() (token, base string) {
	secrets := d.secrets()
	token, base = secrets["AZURE_DEVOPS_TOKEN"], secrets["AZURE_DEVOPS_URL"]
	if token == "" {
		if c, ok := d.storedConnection(connections.AzureDevOps); ok && c.Usable(time.Now()) {
			token, base = c.Access, c.URL
		}
	}
	return token, base
}

// azureBoardsSite is the host of the Azure DevOps the sign-in is for: dev.azure.com by default.
func (d *Daemon) azureBoardsSite() string {
	_, base := d.azureBoardsSignIn()
	if u, err := url.Parse(azuredevopsmcp.BaseURL(base)); err == nil && u.Host != "" {
		return strings.ToLower(u.Host)
	}
	return "dev.azure.com"
}

// forgeAzureBoards is Azure Boards as the azuredevops connector's sign-in on this host (its
// secrets), else the Azure DevOps connection (#3802), or why there is none.
func (d *Daemon) forgeAzureBoards() (forgeAzureBoards, error) {
	token, base := d.azureBoardsSignIn()
	if token == "" {
		return nil, errors.New("Azure DevOps is not connected: connect Azure DevOps in Connectors, with a personal access token with Work Items (read and write)")
	}
	if d.newForgeAzureBoards != nil {
		return d.newForgeAzureBoards(base, token), nil
	}
	return azureboardsmcp.NewRealBoards(base, func() string { return token }, nil), nil
}

// boardsItemOf is a work item in the one model, from folder.
func boardsItemOf(i azureboardsmcp.Item, folder string) wire.ForgeItem {
	out := wire.ForgeItem{Node: boardsNode(i.Project, i.ID), Title: i.Title, State: i.State, Status: optional(i.Status),
		URL: optional(i.URL), Folder: optional(folder), Labels: forgeLabelsOf(i.Labels, nil), Author: optional(i.Author), AuthorAvatar: optional(i.AuthorAvatar), StateReason: optional(i.StateReason),
		Assignees: i.Assignees, UpdatedAt: forgeDate(i.UpdatedAt), CreatedAt: forgeDateOptional(i.CreatedAt), ClosedAt: forgeDateOptional(i.ClosedAt), Comments: int64(i.Comments)}
	if out.Assignees == nil {
		out.Assignees = []string{}
	}
	var parent *wire.LineageNode
	if i.Parent > 0 {
		parent = new(boardsNode(i.Project, i.Parent))
	}
	withHierarchy(&out, parent, i.SubTotal, i.SubDone)
	// An Epic work item is an epic with no epic tag (#3939), so Work ▸ Features counts it.
	if out.Level == nil && strings.EqualFold(i.Type, azureboardsmcp.EpicType) {
		out.Level = new("epic")
	}
	return out
}

// boardsNoPRs is why a work item has no merge, approval, run or diff: Azure Boards has no pull
// requests.
const boardsNoPRs = "Azure Boards has work items only: a pull request is on Azure Repos"

// azureBoardsForge is Azure Boards on the forge interface (#4329, #4359): the work items of the
// projects the folders' .agents/folder.json name in "azureBoardsProjects", through
// forgeAzureBoards. A work item closes, reopens or moves to another state of its type, as a Jira
// issue moves by a transition. Its plan is its parent and predecessor links. Its Caps say it has
// no pull requests. A node is azureboards:organization/project#12.
type azureBoardsForge struct {
	forgeNone
	d *Daemon
}

func (azureBoardsForge) Name() string { return "azureboards" }

func (azureBoardsForge) Images() forgeImageHost { return azureImages{} }

func (azureBoardsForge) Caps() forgeCaps {
	return forgeCaps{
		Issues:      true,
		Issue:       forgeActions{Comment: true, Label: true, Close: true, Reopen: true, Transition: true},
		Avatars:     true,
		StateReason: true,
		CreatedAt:   true, ClosedAt: true, Children: true,
		CommentCount: "exact",
		Plan:         true, BlockedBy: true, AddChild: true,
		Reasons: map[string]string{
			actionAssign:     "the app does not set an Azure Boards work item's assignee yet",
			actionReleases:   "Azure Boards has no releases: it is a tracker, with no repositories",
			actionMerge:      boardsNoPRs,
			actionAutoMerge:  boardsNoPRs,
			actionCancelAuto: boardsNoPRs,
			actionReady:      boardsNoPRs,
			actionApprove:    boardsNoPRs,
			actionRerun:      boardsNoPRs,
			actionLog:        boardsNoPRs,
			actionDiff:       boardsNoPRs,
		},
	}
}

// Owns is azureboards:organization/project#12, a work item.
func (azureBoardsForge) Owns(node wire.LineageNode) (forgeRef, bool) {
	project, id, ok := boardsOfNode(node)
	if !ok {
		return forgeRef{}, false
	}
	return forgeRef{Node: node, Repo: project, Number: id}, true
}

// boardsScope is what an issues list reads of Azure Boards: the projects the folders name,
// organization/project in lower case, each with the first folder that names it.
type boardsScope struct {
	issues        bool
	projects      []string
	projectFolder map[string]string
}

func (s boardsScope) Key() []any { return []any{s.projects} }

// Empty is true for a pull requests list only: a board's list is of a project that no folder
// may name, so an issues list always asks List, which reads Azure Boards only when there is a
// project.
func (s boardsScope) Empty() bool { return !s.issues }

// Sources is the Azure Boards projects of the folders, each once.
func (a azureBoardsForge) Sources(_ context.Context, folders []string, prs bool) (forgeScope, error) {
	s := boardsScope{issues: !prs, projectFolder: map[string]string{}}
	if prs {
		return s, nil
	}
	for _, f := range folders {
		for _, project := range a.d.folderBoardsProjects(f) {
			if _, seen := s.projectFolder[project]; !seen {
				s.projectFolder[project] = f
				s.projects = append(s.projects, project)
			}
		}
	}
	slices.Sort(s.projects)
	return s, nil
}

// List is one query for every project. A board's list is of the work items under its team's area
// paths (#3816), in its project, on the Azure DevOps the board is on: a work item of a project
// that no folder names acts from the board's first folder.
func (a azureBoardsForge) List(ctx context.Context, scope forgeScope, f forgeFilter, cursor string, limit int) (forgePage, error) {
	s, _ := scope.(boardsScope)
	if f.PRs {
		return forgePage{}, nil
	}
	projects, home := s.projects, ""
	if b := f.Board; b != nil {
		if b.azureProject == "" {
			return forgePage{}, nil
		}
		projects, home = []string{b.azureProject}, b.home
	}
	if len(projects) == 0 {
		return forgePage{}, nil
	}
	ab, err := a.d.forgeAzureBoards()
	if err != nil {
		return forgePage{}, err
	}
	sf := azureboardsmcp.SearchFilter{State: f.State, Label: f.Label, Assignee: f.Assignee, Query: f.Query, Feature: f.Feature}
	if b := f.Board; b != nil && b.azureTeam != "" {
		if site := a.d.azureBoardsSite(); !strings.EqualFold(site, b.azureSite) {
			return forgePage{}, errors.New("Azure DevOps is connected at " + site + ", and the board is on " + b.azureSite)
		}
		if sf.Areas, err = ab.TeamAreas(ctx, b.azureProject, b.azureTeam); err != nil {
			return forgePage{}, err
		}
	}
	page, err := ab.Search(ctx, projects, sf, cursor, limit)
	var p forgePage
	for _, i := range page.Items {
		folder, named := s.projectFolder[i.Project]
		if !named {
			folder = home
		}
		p.items = append(p.items, boardsItemOf(i, folder))
	}
	p.cursors, p.next = page.Cursors, page.Next
	return p, err
}

// boardsNotFound is err as a method's answer: a work item Azure Boards does not have is Invalid.
func boardsNotFound(method string, err error) error {
	var be *azureboardsmcp.BoardsError
	if errors.As(err, &be) && be.Kind == azureboardsmcp.NotFound {
		return Invalid("%s: %v", method, err)
	}
	return err
}

// Item is the work item with its description, a page of its comments and the other states of
// its type, as transitions.
func (a azureBoardsForge) Item(ctx context.Context, r forgeRef, cursor string) (wire.ForgeItemDetail, error) {
	ab, err := a.d.forgeAzureBoards()
	if err != nil {
		return wire.ForgeItemDetail{}, err
	}
	p, err := ab.ItemPage(ctx, r.Repo, r.Number, cursor)
	if err != nil {
		return wire.ForgeItemDetail{}, boardsNotFound(itemMethod(r.Node.Kind), err)
	}
	out := wire.ForgeItemDetail{Item: boardsItemOf(p.Item, a.d.boardsFolder(p.Project)), Body: p.Body, Comments: []wire.ForgeComment{},
		Cursor: optional(p.Before), Transitions: []wire.ForgeTransition{}, Children: []wire.ForgeLinked{}}
	out.Start = boardsStart(out.Item)
	for _, c := range p.Children {
		out.Children = append(out.Children, wire.ForgeLinked{Node: boardsNode(c.Project, c.ID), Title: c.Title, State: c.State, URL: optional(c.URL)})
	}
	for _, c := range p.Thread {
		out.Comments = append(out.Comments, forgeCommentOf(c.Author, c.Avatar, c.Body, c.At, c.URL, c.Bot))
	}
	for _, t := range p.Transitions {
		out.Transitions = append(out.Transitions, wire.ForgeTransition{ID: t.ID, Name: t.Name, Category: optional(t.Category)})
	}
	return out, nil
}

// Labels are the tags in use in the work item's project.
func (a azureBoardsForge) Labels(ctx context.Context, r forgeRef) ([]wire.ForgeLabel, error) {
	ab, err := a.d.forgeAzureBoards()
	if err != nil {
		return nil, err
	}
	names, colors, err := ab.Labels(ctx, r.Repo, r.Number)
	if err != nil {
		return nil, err
	}
	return forgeLabelsOf(names, colors), nil
}

// Plan is a work item and its children, each blocked by its predecessors.
func (a azureBoardsForge) Plan(ctx context.Context, r forgeRef) (forgePlanAnswer, error) {
	ab, err := a.d.forgeAzureBoards()
	if err != nil {
		return forgePlanAnswer{}, err
	}
	p, err := ab.Plan(ctx, r.Repo, r.Number)
	if err != nil {
		return forgePlanAnswer{}, boardsNotFound("forge/plan", err)
	}
	out := forgePlanAnswer{epic: boardsItemOf(p.Epic, a.d.boardsFolder(p.Epic.Project))}
	for _, c := range p.Children {
		pc := planChild{item: boardsItemOf(c.Item, a.d.boardsFolder(c.Project))}
		for _, b := range c.BlockedBy {
			pc.blockedBy = append(pc.blockedBy, planRef{node: boardsNode(b.Project, b.ID), open: b.Open})
		}
		out.children = append(out.children, pc)
	}
	return out, nil
}

// Blockers are the predecessors of a standing epic's children (#4242): one read for each project
// they are in, which is the epic's.
func (a azureBoardsForge) Blockers(ctx context.Context, children []forgeRef) (map[forgeRef][]planRef, error) {
	ab, err := a.d.forgeAzureBoards()
	if err != nil {
		return nil, err
	}
	var projects []string
	ids := map[string][]int{}
	for _, c := range children {
		if _, seen := ids[c.Repo]; !seen {
			projects = append(projects, c.Repo)
		}
		ids[c.Repo] = append(ids[c.Repo], c.Number)
	}
	out := map[forgeRef][]planRef{}
	for _, project := range projects {
		by, err := ab.Blockers(ctx, project, ids[project])
		if err != nil {
			return nil, err
		}
		for _, c := range children {
			if c.Repo != project {
				continue
			}
			for _, b := range by[c.Number] {
				out[c] = append(out[c], planRef{node: boardsNode(b.Project, b.ID), open: b.Open})
			}
		}
	}
	return out, nil
}

func (a azureBoardsForge) Comment(ctx context.Context, r forgeRef, body string) (wire.ForgeDone, error) {
	ab, err := a.d.forgeAzureBoards()
	if err != nil {
		return wire.ForgeDone{}, err
	}
	link, err := ab.Comment(ctx, r.Repo, r.Number, body)
	return wire.ForgeDone{URL: optional(link)}, err
}

// SetLabels adds and takes off the work item's tags.
func (a azureBoardsForge) SetLabels(ctx context.Context, r forgeRef, add, remove []string) error {
	ab, err := a.d.forgeAzureBoards()
	if err != nil {
		return err
	}
	return ab.SetTags(ctx, r.Repo, r.Number, add, remove)
}

// SetState moves the work item to the state the page chose, or closes or reopens it by its
// type's own states.
func (a azureBoardsForge) SetState(ctx context.Context, r forgeRef, closed bool, transition string) error {
	ab, err := a.d.forgeAzureBoards()
	if err != nil {
		return err
	}
	if transition != "" {
		return ab.Transition(ctx, r.Repo, r.Number, transition)
	}
	return ab.SetState(ctx, r.Repo, r.Number, closed)
}

// AddChild makes a new work item under the epic, whose type is its level as the project's process
// names it; or moves the work item that child.Issue names (12, AB#12 or its page) under it.
func (a azureBoardsForge) AddChild(ctx context.Context, epic forgeRef, child forgeChild) (wire.ForgeDone, error) {
	const method = "forge/add-child"
	ab, err := a.d.forgeAzureBoards()
	if err != nil {
		return wire.ForgeDone{}, err
	}
	if child.Issue == "" {
		_, link, err := ab.AddChild(ctx, epic.Repo, epic.Number, child.Title, child.Labels, child.Level)
		return wire.ForgeDone{URL: optional(link)}, err
	}
	id, ok := boardsItemID(child.Issue)
	if !ok {
		return wire.ForgeDone{}, Invalid("%s: %q is not a work item: give its id, such as 12 or AB#12, or its page", method, child.Issue)
	}
	if id == epic.Number {
		return wire.ForgeDone{}, Invalid("%s: an epic is not its own child", method)
	}
	return wire.ForgeDone{}, ab.SetParent(ctx, epic.Repo, id, epic.Number)
}

// Links says a predecessor link is within an organization.
func (azureBoardsForge) Links(r, blocker forgeRef) bool {
	return boardsOrg(r.Repo) == boardsOrg(blocker.Repo)
}

func (a azureBoardsForge) SetBlockedBy(ctx context.Context, r, blocker forgeRef, blocked bool) error {
	ab, err := a.d.forgeAzureBoards()
	if err != nil {
		return err
	}
	return ab.SetBlockedBy(ctx, r.Repo, r.Number, blocker.Number, blocked)
}

// boardsLabelNode is the work item a session's label AB#12 names: in the folder's first project.
func (d *Daemon) boardsLabelNode(folder, label string) (wire.LineageNode, bool) {
	m := abLabel.FindStringSubmatch(label)
	projects := d.folderBoardsProjects(folder)
	if m == nil || len(projects) == 0 {
		return wire.LineageNode{}, false
	}
	n, _ := strconv.Atoi(m[1])
	return boardsNode(projects[0], n), n > 0
}

// boardsKeys are the work items, AB#12, that text names, each once: a PR's title or branch.
func boardsKeys(text string) []int {
	var ids []int
	for _, m := range abInText.FindAllStringSubmatch(text, -1) {
		if n, _ := strconv.Atoi(m[1]); n > 0 && !slices.Contains(ids, n) {
			ids = append(ids, n)
		}
	}
	return ids
}

// boardsOfURL is the work item at a web address's path: org/project/_workitems/edit/12, on
// dev.azure.com or an Azure DevOps Server (whose collection is the organization).
func boardsOfURL(path string) (string, int, bool) {
	before, after, ok := strings.Cut(path, "/_workitems/edit/")
	parts := strings.Split(before, "/")
	if !ok || len(parts) < 2 {
		return "", 0, false
	}
	project := strings.ToLower(parts[len(parts)-2] + "/" + parts[len(parts)-1])
	id, err := strconv.Atoi(strings.SplitN(after, "/", 2)[0])
	if err != nil || id <= 0 || !boardsProject.MatchString(project) {
		return "", 0, false
	}
	return project, id, true
}

// boardsItemID is the id of the work item a person names to add as a child: 12, #12, AB#12 or
// its page.
func boardsItemID(ref string) (int, bool) {
	m := boardsItemRef.FindStringSubmatch(strings.TrimSpace(ref))
	if m == nil {
		return 0, false
	}
	n, _ := strconv.Atoi(m[1] + m[2])
	return n, n > 0
}

// boardsStart is the new-agent form for an Azure Boards work item, labelled AB#<id>, the mention
// that links a pull request to it.
func boardsStart(i wire.ForgeItem) *wire.ForgeStart {
	_, id, ok := boardsOfNode(i.Node)
	if !ok {
		return nil
	}
	key := "AB#" + strconv.Itoa(id)
	return &wire.ForgeStart{Prompt: fmt.Sprintf("%s: %s\n\nWork on this Azure Boards work item: %s\n\n"+
		"Name %s in the pull request's title, so Azure Boards links it.", key, i.Title, deref(i.URL), key),
		Labels: []string{key}, Worktree: optional(strconv.Itoa(id) + " " + i.Title)}
}
