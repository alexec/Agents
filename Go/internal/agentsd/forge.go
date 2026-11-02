package agentsd

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/internal/gitlabmcp"
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
// call per project, as GitLab has no list across chosen projects. Linear (#3209) is read with
// the Linear connection, issues only, of the teams the folders' .agents/folder.json name in
// "linearTeams": one query for every team.
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
)

// forgeGitHub is what the forge reads ask of GitHub; a test gives a fake.
type forgeGitHub interface {
	Search(ctx context.Context, repos []string, f githubmcp.SearchFilter, after string, first int) (githubmcp.SearchPage, error)
	ItemPage(ctx context.Context, repo string, number int, before string) (githubmcp.ItemDetail, error)
}

// forgeGitLab is what the forge reads ask of GitLab; a test gives a fake.
type forgeGitLab interface {
	Search(ctx context.Context, projects []string, f gitlabmcp.SearchFilter, after string, first int) (gitlabmcp.SearchPage, error)
	ItemPage(ctx context.Context, project string, number int, mr bool, before string) (gitlabmcp.ItemDetail, error)
}

// forgeLinear is what the forge reads ask of Linear; a test gives a fake.
type forgeLinear interface {
	Search(ctx context.Context, teams []string, f linearmcp.SearchFilter, after string, first int) (linearmcp.SearchPage, error)
	ItemPage(ctx context.Context, identifier, before string) (linearmcp.ItemDetail, error)
}

type forgeAnswer struct {
	at   time.Time
	list *wire.ForgeList
	item *wire.ForgeItemDetail
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
}

// forgeCursor is a list's cursor, one per forge, so a page goes on where each forge stopped.
// Done are the forges whose list has ended.
type forgeCursor struct {
	GitHub string   `json:"github,omitempty"`
	GitLab string   `json:"gitlab,omitempty"`
	Linear string   `json:"linear,omitempty"`
	Done   []string `json:"done,omitempty"`
}

func (c *forgeCursor) of(forge string) *string {
	return map[string]*string{"github": &c.GitHub, "gitlab": &c.GitLab, "linear": &c.Linear}[forge]
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
	sources := d.forgeSources(ctx, prs, folders)
	key, _ := json.Marshal([]any{method, sources.key(), r.State, r.Label, r.Assignee, r.Query, cursor, limit})
	if a, ok := d.forgeCached(string(key)); ok && a.list != nil {
		return *a.list, nil
	}
	out := wire.ForgeList{Items: []wire.ForgeItem{}}
	var pages []forgePage
	if len(sources.repos) > 0 && !slices.Contains(cursor.Done, "github") {
		p := forgePage{forge: "github"}
		gh, err := d.forgeGitHub()
		if err == nil {
			var page githubmcp.SearchPage
			page, err = gh.Search(ctx, sources.repos, githubmcp.SearchFilter{PRs: prs, State: state, Label: deref(r.Label),
				Assignee: deref(r.Assignee), Query: deref(r.Query)}, cursor.GitHub, limit)
			for _, i := range page.Items {
				p.items = append(p.items, forgeItemOf(i, sources.folderOf[forgeRepo{"github", strings.ToLower(i.Repo)}]))
			}
			p.cursors, p.next = page.Cursors, page.Next
		}
		p.err = err
		pages = append(pages, p)
	}
	if (len(sources.gitlab) > 0 || sources.gitlabErr != nil) && !slices.Contains(cursor.Done, "gitlab") {
		p := forgePage{forge: "gitlab", err: sources.gitlabErr}
		if p.err == nil {
			var page gitlabmcp.SearchPage
			page, p.err = d.forgeGitLab(sources.root).Search(ctx, sources.gitlab, gitlabmcp.SearchFilter{MRs: prs, State: state,
				Label: deref(r.Label), Assignee: deref(r.Assignee), Query: deref(r.Query)}, cursor.GitLab, limit)
			for _, i := range page.Items {
				p.items = append(p.items, gitlabItemOf(i, sources.folderOf[forgeRepo{"gitlab", strings.ToLower(i.Project)}]))
			}
			p.cursors, p.next = page.Cursors, page.Next
		}
		pages = append(pages, p)
	}
	if len(sources.teams) > 0 && !slices.Contains(cursor.Done, "linear") {
		p := forgePage{forge: "linear"}
		l, err := d.forgeLinear()
		if err == nil {
			var page linearmcp.SearchPage
			page, err = l.Search(ctx, sources.teams, linearmcp.SearchFilter{State: state, Label: deref(r.Label),
				Assignee: deref(r.Assignee), Query: deref(r.Query)}, cursor.Linear, limit)
			for _, i := range page.Items {
				p.items = append(p.items, linearItemOf(i, sources.teamFolder[i.Team]))
			}
			p.cursors, p.next = page.Cursors, page.Next
		}
		p.err = err
		pages = append(pages, p)
	}
	var more bool
	out.Items, cursor, more = mergeForgePages(pages, cursor, limit)
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
	next := forgeCursor{GitHub: from.GitHub, GitLab: from.GitLab, Linear: from.Linear, Done: slices.Clone(from.Done)}
	more := false
	for n, p := range pages {
		switch {
		case p.err != nil:
		case taken[n] == len(p.items) && p.next == "":
			next.Done = append(next.Done, p.forge)
			*next.of(p.forge) = ""
			continue
		case taken[n] == len(p.items):
			*next.of(p.forge) = p.next
		case taken[n] > 0 && taken[n] <= len(p.cursors):
			*next.of(p.forge) = p.cursors[taken[n]-1]
		}
		more = more || p.err == nil
	}
	return items, next, more
}

// forgeSources are what a list reads: the GitHub repos, the GitLab projects on the connected
// GitLab, and the Linear teams, each once, with a folder on each to act from.
type forgeSources struct {
	repos      []string
	gitlab     []string
	root       string
	gitlabErr  error
	teams      []string
	folderOf   map[forgeRepo]string
	teamFolder map[string]string
}

func (s forgeSources) key() []any { return []any{s.repos, s.root, s.gitlab, s.teams} }

func (d *Daemon) forgeSources(ctx context.Context, prs bool, folders []string) forgeSources {
	s := forgeSources{folderOf: map[forgeRepo]string{}, teamFolder: map[string]string{}}
	gl, glConnected := d.gitlabConnection()
	if glConnected && gl.Usable(nowFunc()) {
		s.root = gitlabmcp.BaseURL(gl.URL)
	}
	elsewhere := false
	for _, f := range folders {
		repo := d.folderRepo(f)
		if _, seen := s.folderOf[repo]; repo.path != "" && !seen {
			switch repo.forge {
			case "github":
				s.folderOf[repo] = f
				s.repos = append(s.repos, repo.path)
			case "gitlab":
				// Only a project on the connected GitLab: its token is for nowhere else.
				if root, project := d.gitlabProjectAt(ctx, f, gl.URL); s.root != "" && root == s.root {
					s.folderOf[repo] = f
					s.gitlab = append(s.gitlab, project)
				} else {
					elsewhere = true
				}
			}
		}
		if prs {
			continue
		}
		for _, team := range d.folderLinearTeams(f) {
			if _, seen := s.teamFolder[team]; !seen {
				s.teamFolder[team] = f
				s.teams = append(s.teams, team)
			}
		}
	}
	slices.Sort(s.repos)
	slices.Sort(s.gitlab)
	slices.Sort(s.teams)
	if len(s.gitlab) == 0 && elsewhere {
		// A page still says why GitLab's folders are not in it.
		s.gitlabErr = errors.New(gitlabmcp.NotConnected)
		if s.root != "" {
			s.gitlabErr = errors.New("GitLab is connected at " + s.root + ", and no folder here is on it")
		}
	}
	return s
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
	m, err := d.approvedConfig(folder)
	if err != nil {
		return nil
	}
	list, _ := m["linearTeams"].([]any)
	var teams []string
	for _, v := range list {
		if t, ok := v.(string); ok && linearTeam.MatchString(strings.ToUpper(t)) {
			teams = append(teams, strings.ToUpper(t))
		}
	}
	return teams
}

// forgeItem is one issue or pull request, with its body and a page of its comments.
func (d *Daemon) forgeItem(ctx context.Context, kind string, r wire.ForgeItemRequest) (wire.ForgeItemDetail, error) {
	method := "forge/" + map[string]string{lineage.KindIssue: "issue", lineage.KindPR: "pull"}[kind]
	if r.Node.Kind != kind {
		return wire.ForgeItemDetail{}, Invalid("%s: the node's kind is %s, not %s", method, r.Node.Kind, kind)
	}
	key, _ := json.Marshal([]any{method, r.Node.Ref, r.Cursor})
	if a, ok := d.forgeCached(string(key)); ok && a.item != nil {
		return *a.item, nil
	}
	var out wire.ForgeItemDetail
	var err error
	if identifier, ok := strings.CutPrefix(r.Node.Ref, "linear:"); ok && kind == lineage.KindIssue && linearLabel.MatchString(identifier) {
		out, err = d.linearItem(ctx, method, identifier, deref(r.Cursor))
	} else if repo, number, ok := nodeOfRepo(r.Node); !ok {
		return wire.ForgeItemDetail{}, Invalid("%s: %s is not an issue or a pull request on GitHub, GitLab or Linear", method, r.Node.Ref)
	} else if repo.forge == "gitlab" {
		out, err = d.gitlabItem(ctx, method, kind, repo, number, deref(r.Cursor))
	} else {
		out, err = d.githubItem(ctx, method, kind, repo, number, deref(r.Cursor))
	}
	if err != nil {
		return wire.ForgeItemDetail{}, err
	}
	d.forgeRemember(string(key), forgeAnswer{item: &out})
	d.resolvedFromForge([]wire.ForgeItem{out.Item})
	return out, nil
}

func (d *Daemon) githubItem(ctx context.Context, method, kind string, repo forgeRepo, number int, cursor string) (wire.ForgeItemDetail, error) {
	gh, err := d.forgeGitHub()
	if err != nil {
		return wire.ForgeItemDetail{}, err
	}
	p, err := gh.ItemPage(ctx, repo.path, number, cursor)
	if err != nil {
		var ge *githubmcp.GitHubError
		if errors.As(err, &ge) && ge.Kind == githubmcp.NotFound {
			return wire.ForgeItemDetail{}, Invalid("%s: %v", method, err)
		}
		return wire.ForgeItemDetail{}, err
	}
	if p.PR != (kind == lineage.KindPR) {
		return wire.ForgeItemDetail{}, Invalid("%s: %s#%d is not %s", method, repo.path, number,
			map[string]string{lineage.KindIssue: "an issue", lineage.KindPR: "a pull request"}[kind])
	}
	out := wire.ForgeItemDetail{Item: forgeItemOf(p.Item, d.repoFolder(repo)), Body: p.Body, Comments: []wire.ForgeComment{}}
	for _, c := range p.Thread {
		out.Comments = append(out.Comments, forgeCommentOf(c.Author, c.Body, c.At, c.URL, c.Bot))
	}
	out.Cursor = optional(p.Before)
	if p.PR {
		out.Checks = []wire.ForgeCheck{}
		for _, c := range p.CheckRuns {
			out.Checks = append(out.Checks, wire.ForgeCheck{Name: c.Name, State: c.State, URL: optional(c.URL)})
		}
		out.ReviewThreads, out.FilesChanged = new(int64(p.ReviewThreads)), new(int64(p.FilesChanged))
	}
	return out, nil
}

// gitlabItem is an issue or merge request on the connected GitLab: a node names its project's
// path only, so a folder on it says which GitLab that is.
func (d *Daemon) gitlabItem(ctx context.Context, method, kind string, repo forgeRepo, number int, cursor string) (wire.ForgeItemDetail, error) {
	gl, connected := d.gitlabConnection()
	if !connected || !gl.Usable(nowFunc()) {
		return wire.ForgeItemDetail{}, errors.New(gitlabmcp.NotConnected)
	}
	root := gitlabmcp.BaseURL(gl.URL)
	folder := d.repoFolder(repo)
	if folder == "" {
		return wire.ForgeItemDetail{}, Invalid("%s: no folder here is on %s", method, repo.path)
	}
	at, project := d.gitlabProjectAt(ctx, folder, gl.URL)
	if at != root {
		return wire.ForgeItemDetail{}, Invalid("%s: %s is not on the connected GitLab, %s", method, repo.path, root)
	}
	p, err := d.forgeGitLab(root).ItemPage(ctx, project, number, kind == lineage.KindPR, cursor)
	if err != nil {
		if gitlabmcp.IsNotFound(err) {
			return wire.ForgeItemDetail{}, Invalid("%s: %v", method, err)
		}
		return wire.ForgeItemDetail{}, err
	}
	out := wire.ForgeItemDetail{Item: gitlabItemOf(p.Item, folder), Body: p.Body, Comments: []wire.ForgeComment{}}
	for _, c := range p.Thread {
		out.Comments = append(out.Comments, forgeCommentOf(c.Author, c.Body, c.At, c.URL, c.Bot))
	}
	out.Cursor = optional(p.Before)
	if p.MR {
		out.Checks = []wire.ForgeCheck{}
		for _, c := range p.CheckRuns {
			out.Checks = append(out.Checks, wire.ForgeCheck{Name: c.Name, State: c.State, URL: optional(c.URL)})
		}
		out.ReviewThreads, out.FilesChanged = new(int64(p.ReviewThreads)), new(int64(p.FilesChanged))
	}
	return out, nil
}

func (d *Daemon) linearItem(ctx context.Context, method, identifier, cursor string) (wire.ForgeItemDetail, error) {
	l, err := d.forgeLinear()
	if err != nil {
		return wire.ForgeItemDetail{}, err
	}
	p, err := l.ItemPage(ctx, identifier, cursor)
	if err != nil {
		var le *linearmcp.LinearError
		if errors.As(err, &le) && le.Kind == linearmcp.NotFound {
			return wire.ForgeItemDetail{}, Invalid("%s: %v", method, err)
		}
		return wire.ForgeItemDetail{}, err
	}
	folder := ""
	for _, f := range d.folderPaths() {
		if slices.Contains(d.folderLinearTeams(f), p.Team) {
			folder = f
			break
		}
	}
	out := wire.ForgeItemDetail{Item: linearItemOf(p.Item, folder), Body: p.Body, Comments: []wire.ForgeComment{}, Cursor: optional(p.Before)}
	for _, c := range p.Thread {
		out.Comments = append(out.Comments, forgeCommentOf(c.Author, c.Body, c.At, c.URL, c.Bot))
	}
	return out, nil
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
	return linearmcp.NewRealLinear("", func() string { return key }), nil
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
		UpdatedAt: forgeDate(i.UpdatedAt), Comments: int64(i.Comments)}
	if out.Assignees == nil {
		out.Assignees = []string{}
	}
	for _, name := range i.Labels {
		out.Labels = append(out.Labels, wire.ForgeLabel{Name: name, Color: optional(i.LabelColors[name])})
	}
	if i.PR {
		out.Draft, out.AutoMerge = new(i.Draft), new(i.AutoMerge)
		out.Checks, out.Review, out.Mergeable = optional(i.Checks), optional(i.Review), optional(i.Mergeable)
	}
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
	}
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
		if _, cached := d.resolveCache[i.Node]; !cached && len(d.resolveCache) >= resolvedCached {
			d.dropOldestResolvedLocked()
		}
		state := i.State
		d.resolveCache[i.Node] = resolvedEntry{resolved: wire.LineageResolved{Title: i.Title, State: &state, Labels: labels}, ok: true, at: now}
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
