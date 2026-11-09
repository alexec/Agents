package agentsd

import (
	"context"
	"errors"
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
	return wire.LineageNode{Kind: lineage.KindIssue, Ref: "azureboards:" + strings.ToLower(project) + "#" + strconv.Itoa(id)}
}

// boardsOfNode is the project and id of a work item's node.
func boardsOfNode(n wire.LineageNode) (string, int, bool) {
	rest, ok := strings.CutPrefix(n.Ref, "azureboards:")
	at := strings.LastIndex(rest, "#")
	if !ok || n.Kind != lineage.KindIssue || at < 0 || !boardsProject.MatchString(rest[:at]) {
		return "", 0, false
	}
	id, err := strconv.Atoi(rest[at+1:])
	if err != nil || id <= 0 {
		return "", 0, false
	}
	return rest[:at], id, true
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
		URL: optional(i.URL), Folder: optional(folder), Labels: forgeLabelsOf(i.Labels, nil), Author: optional(i.Author),
		Assignees: i.Assignees, UpdatedAt: forgeDate(i.UpdatedAt), Comments: int64(i.Comments)}
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

// boardsPage is a page of the work items of projects for a list; with an Azure Boards board,
// of the team's area paths (#3816), on the Azure DevOps the board is on.
func (d *Daemon) boardsPage(ctx context.Context, sources forgeSources, board *forgeBoard, f azureboardsmcp.SearchFilter, after string, limit int) forgePage {
	p := forgePage{forge: "azureboards"}
	b, err := d.forgeAzureBoards()
	if err == nil && board != nil && board.azureTeam != "" {
		if site := d.azureBoardsSite(); !strings.EqualFold(site, board.azureSite) {
			err = errors.New("Azure DevOps is connected at " + site + ", and the board is on " + board.azureSite)
		} else {
			f.Areas, err = b.TeamAreas(ctx, board.azureProject, board.azureTeam)
		}
	}
	if err == nil {
		var page azureboardsmcp.SearchPage
		page, err = b.Search(ctx, sources.boards, f, after, limit)
		for _, i := range page.Items {
			p.items = append(p.items, boardsItemOf(i, sources.boardsFolder[i.Project]))
		}
		p.cursors, p.next = page.Cursors, page.Next
	}
	p.err = err
	return p
}

func (d *Daemon) boardsItem(ctx context.Context, method, project string, id int, cursor string) (wire.ForgeItemDetail, error) {
	b, err := d.forgeAzureBoards()
	if err != nil {
		return wire.ForgeItemDetail{}, err
	}
	p, err := b.ItemPage(ctx, project, id, cursor)
	if err != nil {
		var be *azureboardsmcp.BoardsError
		if errors.As(err, &be) && be.Kind == azureboardsmcp.NotFound {
			return wire.ForgeItemDetail{}, Invalid("%s: %v", method, err)
		}
		return wire.ForgeItemDetail{}, err
	}
	out := wire.ForgeItemDetail{Item: boardsItemOf(p.Item, d.boardsFolder(p.Project)), Body: p.Body, Comments: []wire.ForgeComment{},
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

// boardsPlan is a work item and its children, each blocked by its predecessors.
func (d *Daemon) boardsPlan(ctx context.Context, method, project string, id int) (wire.ForgeItem, []planChild, error) {
	b, err := d.forgeAzureBoards()
	if err != nil {
		return wire.ForgeItem{}, nil, err
	}
	p, err := b.Plan(ctx, project, id)
	if err != nil {
		var be *azureboardsmcp.BoardsError
		if errors.As(err, &be) && be.Kind == azureboardsmcp.NotFound {
			return wire.ForgeItem{}, nil, Invalid("%s: %v", method, err)
		}
		return wire.ForgeItem{}, nil, err
	}
	epic := boardsItemOf(p.Epic, d.boardsFolder(p.Epic.Project))
	var children []planChild
	for _, c := range p.Children {
		pc := planChild{item: boardsItemOf(c.Item, d.boardsFolder(c.Project))}
		for _, r := range c.BlockedBy {
			pc.blockedBy = append(pc.blockedBy, planRef{node: boardsNode(r.Project, r.ID), open: r.Open})
		}
		children = append(children, pc)
	}
	return epic, children, nil
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
