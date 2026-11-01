package agentsd

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"slices"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/internal/lineage"
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
// on, so a list costs one GitHub call however many folders there are. GitLab and Linear say so
// in errors until they are read too.
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

type forgeAnswer struct {
	at   time.Time
	list *wire.ForgeList
	item *wire.ForgeItemDetail
}

type forgeBook struct {
	forgeMu    sync.Mutex
	forgeCache map[string]forgeAnswer
	// newForgeGitHub is GitHub as the token's owner; a test gives a fake.
	newForgeGitHub func(token string) forgeGitHub
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
type forgeCursor struct {
	GitHub string `json:"github,omitempty"`
}

func (c forgeCursor) text() *string {
	if c == (forgeCursor{}) {
		return nil
	}
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
	// The repos, each once, with a folder on it to act from.
	var repos []string
	folderOf := map[string]string{}
	for _, f := range folders {
		repo := d.folderRepo(f)
		if repo.forge != "github" || repo.path == "" {
			continue
		}
		if _, seen := folderOf[repo.path]; !seen {
			folderOf[repo.path] = f
			repos = append(repos, repo.path)
		}
	}
	slices.Sort(repos)
	key, _ := json.Marshal([]any{method, repos, r.State, r.Label, r.Assignee, r.Query, cursor, limit})
	if a, ok := d.forgeCached(string(key)); ok && a.list != nil {
		return *a.list, nil
	}
	out := wire.ForgeList{Items: []wire.ForgeItem{}}
	var next forgeCursor
	if len(repos) > 0 {
		gh, err := d.forgeGitHub()
		if err == nil {
			var page githubmcp.SearchPage
			page, err = gh.Search(ctx, repos, githubmcp.SearchFilter{PRs: prs, State: state, Label: deref(r.Label),
				Assignee: deref(r.Assignee), Query: deref(r.Query)}, cursor.GitHub, limit)
			for _, i := range page.Items {
				out.Items = append(out.Items, forgeItemOf(i, folderOf[i.Repo]))
			}
			next.GitHub = page.Next
		}
		if err != nil {
			out.Errors = append(out.Errors, wire.ForgeListError{Forge: "github", Message: err.Error()})
		}
	}
	out.Cursor = next.text()
	d.forgeRemember(string(key), forgeAnswer{list: &out})
	d.resolvedFromForge(out.Items)
	return out, nil
}

// forgeItem is one issue or pull request, with its body and a page of its comments.
func (d *Daemon) forgeItem(ctx context.Context, kind string, r wire.ForgeItemRequest) (wire.ForgeItemDetail, error) {
	method := "forge/" + map[string]string{lineage.KindIssue: "issue", lineage.KindPR: "pull"}[kind]
	if r.Node.Kind != kind {
		return wire.ForgeItemDetail{}, Invalid("%s: the node's kind is %s, not %s", method, r.Node.Kind, kind)
	}
	repo, number, ok := nodeOfRepo(r.Node)
	if !ok {
		return wire.ForgeItemDetail{}, Invalid("%s: %s is not an issue or a pull request on GitHub or GitLab", method, r.Node.Ref)
	}
	if repo.forge != "github" {
		return wire.ForgeItemDetail{}, Invalid("%s: %s is not read yet", method, repo.forge)
	}
	key, _ := json.Marshal([]any{method, r.Node.Ref, r.Cursor})
	if a, ok := d.forgeCached(string(key)); ok && a.item != nil {
		return *a.item, nil
	}
	gh, err := d.forgeGitHub()
	if err != nil {
		return wire.ForgeItemDetail{}, err
	}
	p, err := gh.ItemPage(ctx, repo.path, number, deref(r.Cursor))
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
		fc := wire.ForgeComment{Author: c.Author, Body: c.Body, At: forgeDate(c.At), URL: optional(c.URL)}
		if c.Bot {
			fc.Bot = new(true)
		}
		out.Comments = append(out.Comments, fc)
	}
	out.Cursor = optional(p.Before)
	if p.PR {
		out.Checks = []wire.ForgeCheck{}
		for _, c := range p.CheckRuns {
			out.Checks = append(out.Checks, wire.ForgeCheck{Name: c.Name, State: c.State, URL: optional(c.URL)})
		}
		out.ReviewThreads, out.FilesChanged = new(int64(p.ReviewThreads)), new(int64(p.FilesChanged))
	}
	d.forgeRemember(string(key), forgeAnswer{item: &out})
	d.resolvedFromForge([]wire.ForgeItem{out.Item})
	return out, nil
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
	return githubmcp.NewRealGitHub("", func() string { return token }, nil), nil
}

// forgeItemOf is a GitHub item in the one model, from folder.
func forgeItemOf(i githubmcp.Item, folder string) wire.ForgeItem {
	repo := forgeRepo{"github", i.Repo}
	node := repo.issue(i.Number)
	if i.PR {
		node = repo.pr(i.Number)
	}
	out := wire.ForgeItem{Node: node, Title: i.Title, State: i.State, URL: optional(i.URL), Folder: optional(folder),
		Labels: []wire.ForgeLabel{}, Author: optional(i.Author), Assignees: i.Assignees, Milestone: optional(i.Milestone),
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
