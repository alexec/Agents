package agentsd

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"maps"
	"net/http"
	"os"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/internal/gitlabmcp"
	"github.com/alexec/agents/Go/internal/jiramcp"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/internal/linearmcp"
	"github.com/alexec/agents/Go/wire"
)

// The forge reads (#3129): forge/issues and forge/pulls list the issues and pull requests of
// this machine's folders, and forge/issue and forge/pull read one with its body and comments,
// in one model for every forge (wire.ForgeItem), for the Work pages (#3100, #3119). Here, on
// the machine, because the forge tokens and the folders are here; the control plane never holds
// them. The client merges the machines' answers, one copy per ref.
//
// GitHub is read with the host's GitHub connection (#1335) through the github connector's own
// client (githubmcp.RealGitHub), not a copy of it: one search for every repo the folders are
// on, so a list costs one GitHub call however many folders there are. GitLab (#3209) is read
// with the host's GitLab connection, only on its own GitLab, through gitlabmcp.RealGitLab: a
// call per project, as GitLab has no list across chosen projects. Linear (#3209, #4357) is read
// with the Linear connection, issues only, of the teams the folders' .agents/folder.json name in
// "linearTeams": one query for every team; when no folder names one, of the whole workspace,
// as the Linear connector's view lists it (#3311) (linearForge). Jira (#3260, #4358) is read with
// the jira connector's sign-in (JIRA_URL, JIRA_EMAIL and JIRA_API_TOKEN in the secrets) through
// jiramcp.RealJira, issues only, of the projects the folders' .agents/folder.json name in
// "jiraProjects": one search for every project (jiraForge). Azure Boards (#3815, #4359) is read the same way, of the projects the
// folders name in "azureBoardsProjects" (azureBoardsForge). Forgejo (#3753, #4354) is read with the
// host's Forgejo connection, only on its own Forgejo, a call per repository (forgejoForge).
// Bitbucket Cloud (#3786, #4355) is read with the host's Bitbucket connection, a call per
// repository (bitbucketForge). Azure Repos (#3803, #4356) is read with the Azure DevOps token
// here, pull requests only, a call per repository (azureDevOpsForge).
//
// A list is one page of every forge, merged by updatedAt: each forge is asked for a page, the
// newest of them all are kept, and each forge's cursor goes on after the last of its own kept.
const (
	// forgeListMost bounds a page of a list; forgeListDefault is a page when not said.
	forgeListMost    = 100
	forgeListDefault = 50
	// forgeCacheFor is how long an answer is kept: a list is read again at most once a minute,
	// however many clients and refreshes ask.
	forgeCacheFor = time.Minute
	// forgeCached bounds the answers kept: the oldest go first.
	forgeCached = 200
	// linearTestVariable is a fixture Linear's GraphQL endpoint, for a walk.
	linearTestVariable = "AGENTS_TEST_LINEAR_URL"
)

// forgeGitHub is what the forge reads ask of GitHub; a test gives a fake.
type forgeGitHub interface {
	Search(ctx context.Context, repos []string, f githubmcp.SearchFilter, after string, first int) (githubmcp.SearchPage, error)
	ItemPage(ctx context.Context, repo string, number int, before string) (githubmcp.ItemDetail, error)
	Plan(ctx context.Context, repo string, number int) (githubmcp.Plan, error)
	// Blockers are the blockers of a standing epic's children (#4200).
	Blockers(ctx context.Context, repo string, numbers []int) (map[int][]githubmcp.Ref, error)
	// WaitingDeploys are the runs waiting for an environment's reviewers (#3587).
	WaitingDeploys(ctx context.Context, repo, workflow, branch string) ([]githubmcp.WaitingDeploy, error)
	// Tags and Compare say what a waiting deploy of a tag ships (#3587).
	Tags(ctx context.Context, repo string) ([]string, error)
	Compare(ctx context.Context, repo, base, head string) ([]githubmcp.Commit, error)
	// Timeline is the epics and releases work/timeline reads (#4172).
	Timeline(ctx context.Context, repo, since string) (githubmcp.Timeline, error)
	forgeGitHubWrites
}

// forgeGitLab is what the forge reads ask of GitLab; a test gives a fake.
type forgeGitLab interface {
	Search(ctx context.Context, projects []string, f gitlabmcp.SearchFilter, after string, first int) (gitlabmcp.SearchPage, error)
	ItemPage(ctx context.Context, project string, number int, mr bool, before string) (gitlabmcp.ItemDetail, error)
	Plan(ctx context.Context, project string, number int) (gitlabmcp.Plan, error)
	// Blockers are the blockers of a standing epic's children (#4242).
	Blockers(ctx context.Context, project string, numbers []int) (map[int][]gitlabmcp.Ref, error)
	// Parents are the parents of a standing epic's issues, for parent: none (#4335).
	Parents(ctx context.Context, project string, numbers []int) (map[int]gitlabmcp.Ref, error)
	GroupBoard(ctx context.Context, group string, id int) (gitlabmcp.BoardScope, error)
	forgeGitLabWrites
}

// forgeJira is what the forge reads and writes ask of Jira; a test gives a fake.
type forgeJira interface {
	Search(ctx context.Context, projects []string, f jiramcp.SearchFilter, after string, first int) (jiramcp.SearchPage, error)
	ItemPage(ctx context.Context, key, before string) (jiramcp.ItemDetail, error)
	Comment(ctx context.Context, key, body string) (string, error)
	SetLabels(ctx context.Context, key string, add, remove []string) error
	Labels(ctx context.Context, key string) ([]string, map[string]string, error)
	SetState(ctx context.Context, key string, closed bool) error
	Transition(ctx context.Context, key, id string) error
	Plan(ctx context.Context, key string) (jiramcp.Plan, error)
	// Blockers are the blockers of a standing epic's children (#4242), by their keys.
	Blockers(ctx context.Context, keys []string) (map[string][]jiramcp.Ref, error)
	BoardFilter(ctx context.Context, board string) (string, error)
}

// forgeLinear is what the forge reads ask of Linear; a test gives a fake.
type forgeLinear interface {
	Search(ctx context.Context, teams []string, f linearmcp.SearchFilter, after string, first int) (linearmcp.SearchPage, error)
	ItemPage(ctx context.Context, identifier, before string) (linearmcp.ItemDetail, error)
	Plan(ctx context.Context, identifier string) (linearmcp.Plan, error)
	// Blockers are the blockers of a standing epic's children (#4242), by their identifiers.
	Blockers(ctx context.Context, identifiers []string) (map[string][]linearmcp.Ref, error)
	forgeLinearWrites
}

type forgeAnswer struct {
	at   time.Time
	list *wire.ForgeList
	item *wire.ForgeItemDetail
	plan *forgePlanAnswer
	// timeline is a repo's read for work/timeline (#4172).
	timeline *githubmcp.Timeline
}

// forgePlanAnswer is an epic and its children as the forge said them (#3267).
type forgePlanAnswer struct {
	epic     wire.ForgeItem
	children []planChild
	// standing is a standing epic's query (#3661), nil for any other epic.
	standing *wire.ForgeStanding
}

type forgeBook struct {
	forgeMu    sync.Mutex
	forgeCache map[string]forgeAnswer
	// forgeRoots is the GitLab each GitLab folder's remote is on, and its project there, read
	// once: a remote seldom changes.
	forgeRoots map[string][2]string
	// newForgeGitHub is GitHub as the token's owner; a test gives a fake.
	newForgeGitHub func(token string) forgeGitHub
	// newForgeGitLab is the GitLab at root as the token's owner; a test gives a fake.
	newForgeGitLab func(root, token string) forgeGitLab
	// newForgeLinear is Linear with the Authorization header's value; a test gives a fake.
	newForgeLinear func(key string) forgeLinear
	// newForgeJira is Jira with the connector's sign-in; a test gives a fake.
	newForgeJira func(auth jiramcp.Auth) forgeJira
	// newForgeAzureBoards is Azure Boards at base with a token; a test gives a fake.
	newForgeAzureBoards func(base, token string) forgeAzureBoards
	// newForgeForgejo is the Forgejo at root as the token's owner; a test gives a fake.
	newForgeForgejo func(root, token string) forgeForgejo
	// newForgeBitbucket is the Bitbucket API at root as the token's owner (with email for an
	// Atlassian API token); a test gives a fake.
	newForgeBitbucket func(root, email, token string) forgeBitbucket
	// newForgeAzureDevOps is the Azure DevOps at root with a token; a test gives a fake.
	newForgeAzureDevOps func(root, token string) forgeAzureDevOps
	// forgeImages are the images forge/image read (#4009), the most recent kept.
	forgeImages forgeImageCache
	// forgeImageTransport reads forge/image's images; a test gives a fake, nil is the default.
	forgeImageTransport http.RoundTripper
}

func (d *Daemon) registerForge() {
	list := func(prs bool) func(context.Context, *Client, wire.ForgeListRequest) (wire.ForgeList, error) {
		return func(ctx context.Context, _ *Client, r wire.ForgeListRequest) (wire.ForgeList, error) {
			return d.forgeList(ctx, prs, r)
		}
	}
	item := func(kind string) func(context.Context, *Client, wire.ForgeItemRequest) (wire.ForgeItemDetail, error) {
		return func(ctx context.Context, _ *Client, r wire.ForgeItemRequest) (wire.ForgeItemDetail, error) {
			return d.forgeItem(ctx, kind, r)
		}
	}
	On(d, wire.CallForgeIssues, list(false))
	On(d, wire.CallForgePulls, list(true))
	On(d, wire.CallForgeIssue, item(lineage.KindIssue))
	On(d, wire.CallForgePull, item(lineage.KindPR))
	d.registerForgePlans()
	d.registerForgeWrites()
	d.registerForgeBoards()
	d.registerForgeImage()
}

// forgeCursor is a list's cursor, one per forge by its name, so a page goes on where each forge
// stopped. Done are the forges whose list has ended. Its JSON is flat, {"github": "…", "done":
// […]}, so a cursor from a daemon before the map (#4360) still reads.
type forgeCursor struct {
	At   map[string]string
	Done []string
}

// set is where forge goes on from; "" is from its start.
func (c *forgeCursor) set(forge, at string) {
	if at == "" {
		delete(c.At, forge)
		return
	}
	if c.At == nil {
		c.At = map[string]string{}
	}
	c.At[forge] = at
}

func (c forgeCursor) MarshalJSON() ([]byte, error) {
	m := map[string]any{}
	for forge, at := range c.At {
		if at != "" {
			m[forge] = at
		}
	}
	if len(c.Done) > 0 {
		m["done"] = c.Done
	}
	return json.Marshal(m)
}

func (c *forgeCursor) UnmarshalJSON(b []byte) error {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(b, &m); err != nil {
		return err
	}
	*c = forgeCursor{}
	for k, v := range m {
		if k == "done" {
			if err := json.Unmarshal(v, &c.Done); err != nil {
				return err
			}
			continue
		}
		var at string
		if err := json.Unmarshal(v, &at); err != nil {
			return err
		}
		c.set(k, at)
	}
	return nil
}

func (c forgeCursor) text() *string {
	b, _ := json.Marshal(c)
	s := base64.RawURLEncoding.EncodeToString(b)
	return &s
}

func cursorOf(s *string) (forgeCursor, error) {
	var c forgeCursor
	if s == nil || *s == "" {
		return c, nil
	}
	b, err := base64.RawURLEncoding.DecodeString(*s)
	if err != nil || json.Unmarshal(b, &c) != nil {
		return c, errors.New("the cursor is not one a list gave")
	}
	return c, nil
}

// forgeList is a page of the issues or pull requests of r.folder, or of every folder.
func (d *Daemon) forgeList(ctx context.Context, prs bool, r wire.ForgeListRequest) (wire.ForgeList, error) {
	method := map[bool]string{false: "forge/issues", true: "forge/pulls"}[prs]
	limit := forgeListDefault
	if r.Limit != nil {
		if *r.Limit < 1 || *r.Limit > forgeListMost {
			return wire.ForgeList{}, Invalid("%s: limit is 1 to %d", method, forgeListMost)
		}
		limit = int(*r.Limit)
	}
	state := deref(r.State)
	if !slices.Contains([]string{"", "open", "closed", "all"}, state) {
		return wire.ForgeList{}, Invalid("%s: state is open, closed or all", method)
	}
	cursor, err := cursorOf(r.Cursor)
	if err != nil {
		return wire.ForgeList{}, Invalid("%s: %v", method, err)
	}
	folders := d.folderPaths()
	if f := deref(r.Folder); f != "" {
		if !slices.Contains(folders, f) {
			return wire.ForgeList{}, Invalid("%s: %s is not a folder on this machine", method, f)
		}
		folders = []string{f}
	}
	var board *forgeBoard
	var boardWire wire.ProjectBoard
	if url := deref(r.Board); url != "" {
		var in []string
		var ok bool
		if boardWire, in, ok = d.boardIn(folders, url); !ok {
			return wire.ForgeList{Items: []wire.ForgeItem{}}, nil
		}
		folders = in
	}
	if deref(r.Board) != "" {
		board = narrowToBoard(boardWire, folders, prs)
	}
	filter := forgeFilter{PRs: prs, State: state, Label: deref(r.Label), Assignee: deref(r.Assignee), Query: deref(r.Query),
		Feature: deref(r.Feature), Board: board}
	// The forges on the interface (#4329): each one's scope, and why it left folders out.
	type scoped struct {
		forge Forge
		scope forgeScope
		err   error
	}
	var moved []scoped
	scopeKeys := []any{}
	for _, f := range d.forges() {
		// A board's list is of the board's forge only.
		if board != nil && board.forge != f.Name() {
			continue
		}
		s, err := f.Sources(ctx, folders, prs)
		if board != nil {
			// A board's list is of the board's own projects: it says nothing of folders left out.
			err = nil
		}
		if s == nil || s.Empty() && err == nil {
			continue
		}
		moved = append(moved, scoped{f, s, err})
		scopeKeys = append(scopeKeys, f.Name(), s.Key())
	}
	key, _ := json.Marshal([]any{method, scopeKeys, board.key(), r.State, r.Label, r.Assignee, r.Query, r.Feature, cursor, limit})
	if a, ok := d.forgeCached(string(key)); ok && a.list != nil {
		return *a.list, nil
	}
	out := wire.ForgeList{Items: []wire.ForgeItem{}}
	var pages []forgePage
	for _, m := range moved {
		name := m.forge.Name()
		if slices.Contains(cursor.Done, name) {
			continue
		}
		p := forgePage{err: m.err}
		if p.err == nil {
			p, p.err = m.forge.List(ctx, m.scope, filter, cursor.At[name], limit)
		}
		p.forge = name
		pages = append(pages, p)
	}
	var more bool
	out.Items, cursor, more = mergeForgePages(pages, cursor, limit)
	// What each forge with an item on the page fills, so a client draws its rows (#4361).
	for _, m := range moved {
		if slices.ContainsFunc(out.Items, func(i wire.ForgeItem) bool { _, ok := m.forge.Owns(i.Node); return ok }) {
			out.Forges = append(out.Forges, m.forge.Caps().wire(m.forge.Name()))
		}
	}
	for _, p := range pages {
		if p.err != nil {
			out.Errors = append(out.Errors, wire.ForgeListError{Forge: p.forge, Message: p.err.Error()})
		}
	}
	if more {
		out.Cursor = cursor.text()
	}
	d.forgeRemember(string(key), forgeAnswer{list: &out})
	d.resolvedFromForge(out.Items)
	return out, nil
}

// forgePage is one forge's page of a list: cursors[i] goes on after items[i], next after the
// page ("" at its end); or why the forge could not be read.
type forgePage struct {
	forge   string
	items   []wire.ForgeItem
	cursors []string
	next    string
	err     error
}

// mergeForgePages keeps the newest limit items of the forges' pages, each forge's in its own
// order, and the cursor that goes on after them: each forge from the last of its own kept, a
// forge whose page was all kept and was its last is done, and a forge that failed is asked
// again from where it was. more says some forge goes on.
func mergeForgePages(pages []forgePage, from forgeCursor, limit int) ([]wire.ForgeItem, forgeCursor, bool) {
	items := []wire.ForgeItem{}
	taken := make([]int, len(pages))
	for len(items) < limit {
		best := -1
		for n, p := range pages {
			if taken[n] < len(p.items) && (best < 0 || p.items[taken[n]].UpdatedAt > pages[best].items[taken[best]].UpdatedAt) {
				best = n
			}
		}
		if best < 0 {
			break
		}
		items = append(items, pages[best].items[taken[best]])
		taken[best]++
	}
	next := forgeCursor{At: maps.Clone(from.At), Done: slices.Clone(from.Done)}
	more := false
	for n, p := range pages {
		switch {
		case p.err != nil:
		case taken[n] == len(p.items) && p.next == "":
			next.Done = append(next.Done, p.forge)
			next.set(p.forge, "")
			continue
		case taken[n] == len(p.items):
			next.set(p.forge, p.next)
		case taken[n] > 0 && taken[n] <= len(p.cursors):
			next.set(p.forge, p.cursors[taken[n]-1])
		}
		more = more || p.err == nil
	}
	return items, next, more
}

// gitlabProjectAt is the GitLab a folder's remote is on (connected first), and its project there.
func (d *Daemon) gitlabProjectAt(ctx context.Context, folder, connected string) (root, project string) {
	key := folder + " " + connected
	d.forgeMu.Lock()
	at, ok := d.forgeRoots[key]
	d.forgeMu.Unlock()
	if ok {
		return at[0], at[1]
	}
	gitCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var roots []string
	if connected != "" {
		roots = append(roots, connected)
	}
	root, project, _ = gitlabmcp.ProjectAt(gitCtx, folder, append(roots, connections.GitLabCom))
	d.forgeMu.Lock()
	defer d.forgeMu.Unlock()
	if d.forgeRoots == nil || len(d.forgeRoots) >= forgeCached {
		d.forgeRoots = map[string][2]string{}
	}
	d.forgeRoots[key] = [2]string{root, project}
	return root, project
}

// folderLinearTeams is the Linear teams, by key, that a folder's .agents/folder.json names for
// its tasks: "linearTeams": ["ENG"].
func (d *Daemon) folderLinearTeams(folder string) []string {
	return d.folderKeys(folder, "linearTeams")
}

// linearFolder is the first folder whose .agents/folder.json names team, or, when no folder
// names any, the folder the whole workspace acts from (#3311); else "".
func (d *Daemon) linearFolder(team string) string {
	for _, f := range d.folderPaths() {
		if slices.Contains(d.folderLinearTeams(f), team) {
			return f
		}
	}
	if d.anyLinearTeams() {
		return ""
	}
	return d.linearHome()
}

// anyLinearTeams says some folder here names Linear teams: then Work lists only theirs.
func (d *Daemon) anyLinearTeams() bool {
	for _, f := range d.folderPaths() {
		if len(d.folderLinearTeams(f)) > 0 {
			return true
		}
	}
	return false
}

// linearHome is the folder a workspace's Linear issues act from (Start Agent): the first one
// whose Linear connector is set up and approved, as the connector's row was (#2032), else the
// first folder.
func (d *Daemon) linearHome() string {
	folders := d.folderPaths()
	for _, f := range folders {
		for _, name := range d.viewServerNames(f) {
			if s, problem := d.viewServerFor(name, f); problem == 0 {
				if ours, ok := oursForServer(s); ok && ours.ID == "agents/linear" {
					return f
				}
			}
		}
	}
	if len(folders) == 0 {
		return ""
	}
	return folders[0]
}

// folderJiraProjects is the Jira projects, by key, that a folder's .agents/folder.json names
// for its tasks: "jiraProjects": ["PROJ"] (#3260).
func (d *Daemon) folderJiraProjects(folder string) []string {
	return d.folderKeys(folder, "jiraProjects")
}

// folderKeys is the team or project keys (ENG, PROJ) a folder's .agents/folder.json lists
// under name, in capitals.
func (d *Daemon) folderKeys(folder, name string) []string {
	m, err := d.approvedConfig(folder)
	if err != nil {
		return nil
	}
	list, _ := m[name].([]any)
	var keys []string
	for _, v := range list {
		if t, ok := v.(string); ok && linearTeam.MatchString(strings.ToUpper(t)) {
			keys = append(keys, strings.ToUpper(t))
		}
	}
	return keys
}

// jiraFolder is the first folder whose .agents/folder.json names project, or "".
func (d *Daemon) jiraFolder(project string) string {
	for _, f := range d.folderPaths() {
		if slices.Contains(d.folderJiraProjects(f), project) {
			return f
		}
	}
	return ""
}

// forgeItem is one issue or pull request, with its body and a page of its comments.
func (d *Daemon) forgeItem(ctx context.Context, kind string, r wire.ForgeItemRequest) (wire.ForgeItemDetail, error) {
	method := itemMethod(kind)
	if r.Node.Kind != kind {
		return wire.ForgeItemDetail{}, Invalid("%s: the node's kind is %s, not %s", method, r.Node.Kind, kind)
	}
	key, _ := json.Marshal([]any{method, r.Node.Ref, r.Cursor})
	if a, ok := d.forgeCached(string(key)); ok && a.item != nil {
		return *a.item, nil
	}
	f, ref, ok := d.forgeOwning(r.Node)
	if !ok {
		return wire.ForgeItemDetail{}, Invalid("%s: %s is not an issue or a pull request on GitHub, GitLab, Forgejo, Bitbucket, Azure DevOps, Linear, Jira or Azure Boards", method, r.Node.Ref)
	}
	out, err := f.Item(ctx, ref, deref(r.Cursor))
	if err != nil {
		return wire.ForgeItemDetail{}, forgeCannotErr(method, f, err)
	}
	out.Actions = f.Caps().itemActions(out)
	d.forgeRemember(string(key), forgeAnswer{item: &out})
	d.resolvedFromForge([]wire.ForgeItem{out.Item})
	return out, nil
}

// gitlabOf is the connected GitLab, the project of repo there and a folder on it: a node names
// its project's path only, so a folder on it says which GitLab that is.
func (d *Daemon) gitlabOf(ctx context.Context, method string, repo forgeRepo) (forgeGitLab, string, string, error) {
	gl, connected := d.gitlabConnection()
	if !connected || !gl.Usable(nowFunc()) {
		return nil, "", "", errors.New(gitlabmcp.NotConnected)
	}
	root := gitlabmcp.BaseURL(gl.URL)
	folder := d.repoFolder(repo)
	if folder == "" {
		return nil, "", "", Invalid("%s: no folder here is on %s", method, repo.path)
	}
	at, project := d.gitlabProjectAt(ctx, folder, gl.URL)
	if at != root {
		return nil, "", "", Invalid("%s: %s is not on the connected GitLab, %s", method, repo.path, root)
	}
	return d.forgeGitLab(root), project, folder, nil
}

func forgeCommentOf(author, body, at, url string, bot bool) wire.ForgeComment {
	c := wire.ForgeComment{Author: author, Body: body, At: forgeDate(at), URL: optional(url)}
	if bot {
		c.Bot = new(true)
	}
	return c
}

// forgeGitHub is GitHub as the person's connection on this host, or why there is none.
func (d *Daemon) forgeGitHub() (forgeGitHub, error) {
	c, ok := d.githubConnection()
	if !ok || !c.Usable(nowFunc()) {
		return nil, errors.New(githubmcp.NotConnected)
	}
	if d.newForgeGitHub != nil {
		return d.newForgeGitHub(c.Access), nil
	}
	token := c.Access
	// A walk points GitHub at its fixture server (AGENTS_TEST_GITHUB_URL), as the skill catalogue does.
	api := ""
	if e := d.catalogEndpoints(); !e.IsLive() {
		api = e.API
	}
	return githubmcp.NewRealGitHub(api, func() string { return token }, nil), nil
}

// forgeGitLab is the GitLab at root as the person's connection; the caller has checked there is one.
func (d *Daemon) forgeGitLab(root string) forgeGitLab {
	c, _ := d.gitlabConnection()
	if d.newForgeGitLab != nil {
		return d.newForgeGitLab(root, c.Access)
	}
	token := c.Access
	return gitlabmcp.NewRealGitLab(root, func() string { return token }, nil)
}

// forgeLinear is Linear as the person's connection on this host, or why there is none.
func (d *Daemon) forgeLinear() (forgeLinear, error) {
	s, err := d.connectionStore()
	var c connections.Connection
	ok := false
	if err == nil {
		c, ok, err = s.Get(connections.Linear)
	}
	if err != nil || !ok || !c.Usable(nowFunc()) {
		return nil, errors.New("Linear is not connected, or its token ended: connect Linear in Connectors")
	}
	// The connection's token is OAuth's, which says Bearer.
	key := "Bearer " + c.Access
	if d.newForgeLinear != nil {
		return d.newForgeLinear(key), nil
	}
	// A walk points Linear at its fixture server (#3311), as AGENTS_TEST_GITHUB_URL does GitHub.
	return linearmcp.NewRealLinear(os.Getenv(linearTestVariable), func() string { return key }), nil
}

// linearConnected says this host has a Linear connection, usable or not: a list without one
// leaves Linear out, with no error, as most people have no Linear.
func (d *Daemon) linearConnected() bool {
	s, err := d.connectionStore()
	if err != nil {
		return false
	}
	_, ok, err := s.Get(connections.Linear)
	return err == nil && ok
}

// forgeJira is Jira as the jira connector's sign-in on this host (its secrets), or why there is none.
func (d *Daemon) forgeJira() (forgeJira, error) {
	secrets := d.secrets()
	auth := jiramcp.TokenAuth(secrets["JIRA_URL"], secrets["JIRA_EMAIL"], secrets["JIRA_API_TOKEN"])
	if auth.Site == "" || auth.Header == "" {
		return nil, errors.New("Jira is not signed in: add the Jira connector in Connectors, with its site and API token")
	}
	if d.newForgeJira != nil {
		return d.newForgeJira(auth), nil
	}
	return jiramcp.NewRealJira(func() jiramcp.Auth { return auth }), nil
}

// forgeItemOf is a GitHub item in the one model, from folder.
func forgeItemOf(i githubmcp.Item, folder string) wire.ForgeItem {
	// Lineage refs are lower case; GitHub says the repo as its owner wrote it.
	repo := forgeRepo{"github", strings.ToLower(i.Repo)}
	node := repo.issue(i.Number)
	if i.PR {
		node = repo.pr(i.Number)
	}
	out := wire.ForgeItem{Node: node, Title: i.Title, State: i.State, URL: optional(i.URL), Folder: optional(folder),
		Author: optional(i.Author), Assignees: i.Assignees, Milestone: optional(i.Milestone),
		Labels: forgeLabelsOf(i.Labels, i.LabelColors), UpdatedAt: forgeDate(i.UpdatedAt), Comments: int64(i.Comments)}
	if out.Assignees == nil {
		out.Assignees = []string{}
	}
	if i.PR {
		out.Draft, out.AutoMerge = new(i.Draft), new(i.AutoMerge)
		out.Checks, out.Review, out.Mergeable = optional(i.Checks), optional(i.Review), optional(i.Mergeable)
		return out
	}
	var parent *wire.LineageNode
	if i.ParentRepo != "" {
		parent = new(forgeRepo{"github", strings.ToLower(i.ParentRepo)}.issue(i.ParentNumber))
	}
	withHierarchy(&out, parent, i.SubTotal, i.SubDone)
	return out
}

// gitlabItemOf is a GitLab item in the one model, from folder.
func gitlabItemOf(i gitlabmcp.Item, folder string) wire.ForgeItem {
	repo := forgeRepo{"gitlab", strings.ToLower(i.Project)}
	node := repo.issue(i.Number)
	if i.MR {
		node = repo.pr(i.Number)
	}
	out := wire.ForgeItem{Node: node, Title: i.Title, State: i.State, URL: optional(i.URL), Folder: optional(folder),
		Labels: forgeLabelsOf(i.Labels, i.LabelColors), Author: optional(i.Author), Assignees: i.Assignees,
		Milestone: optional(i.Milestone), UpdatedAt: forgeDate(i.UpdatedAt), Comments: int64(i.Comments)}
	if out.Assignees == nil {
		out.Assignees = []string{}
	}
	if i.MR {
		out.Draft, out.AutoMerge = new(i.Draft), new(i.AutoMerge)
		out.Checks, out.Review, out.Mergeable = optional(i.Checks), optional(i.Review), optional(i.Mergeable)
		return out
	}
	var parent *wire.LineageNode
	if i.ParentProject != "" {
		parent = new(forgeRepo{"gitlab", strings.ToLower(i.ParentProject)}.issue(i.ParentNumber))
	}
	withHierarchy(&out, parent, i.SubTotal, i.SubDone)
	return out
}

// linearItemOf is a Linear issue in the one model, from folder.
func linearItemOf(i linearmcp.Item, folder string) wire.ForgeItem {
	out := wire.ForgeItem{Node: wire.LineageNode{Kind: lineage.KindIssue, Ref: "linear:" + i.Identifier}, Title: i.Title, State: i.State,
		URL: optional(i.URL), Folder: optional(folder), Labels: forgeLabelsOf(i.Labels, i.LabelColors), Author: optional(i.Author),
		Assignees: i.Assignees, Milestone: optional(i.Milestone), UpdatedAt: forgeDate(i.UpdatedAt), Comments: int64(i.Comments)}
	if out.Assignees == nil {
		out.Assignees = []string{}
	}
	var parent *wire.LineageNode
	if i.Parent != "" {
		parent = &wire.LineageNode{Kind: lineage.KindIssue, Ref: "linear:" + i.Parent}
	}
	withHierarchy(&out, parent, i.SubTotal, i.SubDone)
	return out
}

// jiraItemOf is a Jira issue in the one model, from folder.
func jiraItemOf(i jiramcp.Item, folder string) wire.ForgeItem {
	out := wire.ForgeItem{Node: wire.LineageNode{Kind: lineage.KindIssue, Ref: "jira:" + i.Key}, Title: i.Title, State: i.State,
		Status: optional(i.Status), URL: optional(i.URL), Folder: optional(folder), Labels: forgeLabelsOf(i.Labels, nil),
		Author: optional(i.Author), Assignees: i.Assignees, Milestone: optional(i.Milestone), UpdatedAt: forgeDate(i.UpdatedAt),
		Comments: int64(i.Comments)}
	if out.Assignees == nil {
		out.Assignees = []string{}
	}
	var parent *wire.LineageNode
	if i.Parent != "" {
		parent = &wire.LineageNode{Kind: lineage.KindIssue, Ref: "jira:" + i.Parent}
	}
	withHierarchy(&out, parent, i.SubTotal, i.SubDone)
	return out
}

func forgeLabelsOf(names []string, colors map[string]string) []wire.ForgeLabel {
	out := []wire.ForgeLabel{}
	for _, name := range names {
		out = append(out, wire.ForgeLabel{Name: name, Color: optional(colors[name])})
	}
	return out
}

// resolvedFromForge keeps what the lists read in the lineage cache (#3089), so a walk to an
// item a page has shown has its title without asking the forge again.
func (d *Daemon) resolvedFromForge(items []wire.ForgeItem) {
	now := nowFunc()
	d.resolveMu.Lock()
	defer d.resolveMu.Unlock()
	if d.resolveCache == nil {
		d.resolveCache = map[wire.LineageNode]resolvedEntry{}
	}
	for _, i := range items {
		labels := make([]string, len(i.Labels))
		for n, l := range i.Labels {
			labels[n] = l.Name
		}
		had, cached := d.resolveCache[i.Node]
		if !cached && len(d.resolveCache) >= resolvedCached {
			d.dropOldestResolvedLocked()
		}
		state := i.State
		parent := had.parent
		if i.Parent != nil {
			p := *i.Parent
			parent = &p
		}
		d.resolveCache[i.Node] = resolvedEntry{resolved: wire.LineageResolved{Title: i.Title, State: &state, Labels: labels}, ok: true, at: now, parent: parent}
	}
}

func (d *Daemon) forgeCached(key string) (forgeAnswer, bool) {
	d.forgeMu.Lock()
	defer d.forgeMu.Unlock()
	a, ok := d.forgeCache[key]
	if !ok || nowFunc().Sub(a.at) >= forgeCacheFor {
		return forgeAnswer{}, false
	}
	return a, true
}

// forgeRemember keeps an answer for forgeCacheFor; an answer with an error is not kept, so
// the next ask tries again.
func (d *Daemon) forgeRemember(key string, a forgeAnswer) {
	if a.list != nil && len(a.list.Errors) > 0 {
		return
	}
	a.at = nowFunc()
	d.forgeMu.Lock()
	defer d.forgeMu.Unlock()
	if d.forgeCache == nil {
		d.forgeCache = map[string]forgeAnswer{}
	}
	if _, ok := d.forgeCache[key]; !ok && len(d.forgeCache) >= forgeCached {
		var oldest string
		var at time.Time
		for k, e := range d.forgeCache {
			if at.IsZero() || e.at.Before(at) {
				oldest, at = k, e.at
			}
		}
		delete(d.forgeCache, oldest)
	}
	d.forgeCache[key] = a
}

// forgeDate is an RFC 3339 time from the forge on the wire; 0 when it says none.
func forgeDate(s string) wire.Date {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return 0
	}
	return wire.DateOf(t)
}

func optional(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}
