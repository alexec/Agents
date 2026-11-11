package agentsd

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/forgejomcp"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// Forgejo and Gitea on the Work pages (#3753, after GitLab's #3209): the issues and pull
// requests of the folders whose git remote is on the connected Forgejo (#3752), read and
// written with that connection through forgejomcp.RealForgejo, a call per repository, as
// Forgejo has no list across chosen repositories. Its token goes only to its own Forgejo, so a
// folder on another Forgejo is left out, and the list says why. An issue or a pull request is
// the node forgejo:owner/repo#12, in lower case: Forgejo numbers them together, so both say #.
//
// Forgejo's API has no way to run a check again or to read an Actions job's log, so a pull
// request's page sends those to Forgejo's own page: forgejoForge's Caps say so.

// forgeForgejo is what the forge reads and writes ask of Forgejo; a test gives a fake.
type forgeForgejo interface {
	Search(ctx context.Context, repos []string, f forgejomcp.SearchFilter, after string, first int) (forgejomcp.SearchPage, error)
	ItemPage(ctx context.Context, repo string, number int, pr bool, before string) (forgejomcp.ItemDetail, error)
	Comment(ctx context.Context, repo string, number int, body string) (string, error)
	SetLabels(ctx context.Context, repo string, number int, add, remove []string) error
	SetAssignees(ctx context.Context, repo string, number int, add, remove []string) error
	SetState(ctx context.Context, repo string, number int, closed bool) error
	RepoLabels(ctx context.Context, repo string) ([]string, map[string]string, error)
	MergeMethods(ctx context.Context, repo string) ([]string, error)
	Merge(ctx context.Context, repo string, number int, sha, method string, auto bool) error
	// The pull request page's Auto-merge row and Draft state (#4410).
	CancelAutoMerge(ctx context.Context, repo string, number int) error
	MarkReady(ctx context.Context, repo string, number int) error
	Approve(ctx context.Context, repo string, number int, sha string) (string, error)
	PRDiff(ctx context.Context, repo string, number int) (map[string]any, error)
	// What lineage asks (lineageforgejo.go).
	Node(ctx context.Context, repo string, number int) (forgejomcp.Node, error)
	CommitTime(ctx context.Context, repo, ref string) (time.Time, error)
	Compare(ctx context.Context, repo, base, head string) ([]forgejomcp.Commit, error)
	CommitPR(ctx context.Context, repo, sha string) (int, error)
	// Releases are a repository's newest releases (#4426).
	Releases(ctx context.Context, repo string, limit int) ([]forgejomcp.RepoRelease, error)
	CostComment(ctx context.Context, repo string, number int, id, mark, body string) (string, error)
	Plan(ctx context.Context, repo string, number int) (forgejomcp.Plan, error)
	// Blockers are the blockers of a standing epic's children (#4242).
	Blockers(ctx context.Context, repo string, numbers []int) (map[int][]forgejomcp.Ref, error)
	// Parents are the epics of a standing epic's issues, for parent: none (#4335).
	Parents(ctx context.Context, repo string, numbers []int) (map[int]forgejomcp.Ref, error)
	CreateIssue(ctx context.Context, repo, title string, labels []string) (int, string, error)
	SetBlockedBy(ctx context.Context, repo string, number int, blockerRepo string, blockerNumber int, blocked bool) error
}

// forgejoNoChecksAPI is why a Forgejo pull request's checks are not run again or read here.
const forgejoNoChecksAPI = "Forgejo's API cannot run a check again or give its log: open the check on Forgejo"

// forgejoOfNode is the repository, owner/repo, and the number of a Forgejo issue's or pull
// request's node.
func forgejoOfNode(n wire.LineageNode) (string, int, bool) {
	rest, ok := strings.CutPrefix(n.Ref, "forgejo:")
	at := strings.LastIndex(rest, "#")
	if !ok || (n.Kind != lineage.KindIssue && n.Kind != lineage.KindPR) || at < 0 || strings.Count(rest[:at], "/") != 1 {
		return "", 0, false
	}
	number, err := strconv.Atoi(rest[at+1:])
	if err != nil || number <= 0 || strings.HasPrefix(rest, "/") || strings.HasSuffix(rest[:at], "/") {
		return "", 0, false
	}
	return rest[:at], number, true
}

// forgejoNode is an issue's or a pull request's node.
func forgejoNode(repo string, number int, pr bool) wire.LineageNode {
	kind := lineage.KindIssue
	if pr {
		kind = lineage.KindPR
	}
	return wire.LineageNode{Kind: kind, Ref: "forgejo:" + strings.ToLower(repo) + "#" + strconv.Itoa(number)}
}

// forgejoRoot is the connected Forgejo's root, when its connection is usable; else "".
func (d *Daemon) forgejoRoot() (connections.Connection, string) {
	c, connected := d.forgejoConnection()
	if !connected || !c.Usable(nowFunc()) {
		return c, ""
	}
	return c, forgejomcp.BaseURL(c.URL)
}

// forgejoRepoAt is the Forgejo a folder's remote is on (connected first, then Codeberg, then a
// host named forgejo, gitea or codeberg), and its repository there; read once, as GitLab's.
func (d *Daemon) forgejoRepoAt(ctx context.Context, folder, connected string) (root, repo string) {
	key := "forgejo " + folder + " " + connected
	d.forgeMu.Lock()
	at, ok := d.forgeRoots[key]
	d.forgeMu.Unlock()
	if ok {
		return at[0], at[1]
	}
	gitCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	roots := []string{connections.Codeberg}
	if connected != "" {
		roots = append([]string{connected}, roots...)
	}
	root, repo, _ = forgejomcp.RepoAt(gitCtx, folder, roots)
	d.forgeMu.Lock()
	defer d.forgeMu.Unlock()
	if d.forgeRoots == nil || len(d.forgeRoots) >= forgeCached {
		d.forgeRoots = map[string][2]string{}
	}
	d.forgeRoots[key] = [2]string{root, repo}
	return root, repo
}

// onGitHubOrGitLab says r is a GitHub or GitLab repo, which the Forgejo lists leave to theirs.
func onGitHubOrGitLab(r forgeRepo) bool { return r.forge == "github" || r.forge == "gitlab" }

// forgejoForge is Forgejo and Gitea on the forge interface (#4329, #4354): the host's Forgejo
// connection, only on its own Forgejo, through forgeForgejo. A node names its repository only, so
// a folder on it says which Forgejo that is (forgejoOf). The parents of a standing epic's issues
// (Parents) stay on forgeForgejo, which forgestanding.go asks with forgejoOf.
type forgejoForge struct {
	forgeNone
	d *Daemon
}

func (forgejoForge) Name() string { return "forgejo" }

func (forgejoForge) Images() forgeImageHost { return forgejoImages{} }

func (forgejoForge) Caps() forgeCaps {
	return forgeCaps{
		Issues: true, PRs: true,
		Issue: forgeActions{Comment: true, Label: true, Assign: true, Close: true, Reopen: true},
		PR: forgeActions{Comment: true, Label: true, Assign: true, Close: true, Reopen: true, Merge: true, AutoMerge: true, Approve: true,
			Diff: true, CancelAutoMerge: true, Ready: true},
		LabelColors: true,
		Avatars:     true,
		CreatedAt:   true, ClosedAt: true,
		// A pull request's branches and merge (#4409); its size, reviewers, closing issues and check times are #4682.
		Branches: true, MergedBy: true, MergeCommit: true,
		CommentCount: "exact",
		Releases:     true,
		Plan:         true, BlockedBy: true, AddChild: true,
		Reasons: map[string]string{
			actionTransition: "only a Jira issue or an Azure Boards work item moves by a transition",
			actionRerun:      forgejoNoChecksAPI,
			actionLog:        forgejoNoChecksAPI,
		},
	}
}

// Owns is forgejo:owner/repo#12, an issue or a pull request.
func (forgejoForge) Owns(node wire.LineageNode) (forgeRef, bool) {
	repo, number, ok := forgejoOfNode(node)
	if !ok {
		return forgeRef{}, false
	}
	return forgeRef{Node: node, Repo: repo, Number: number}, true
}

// forgejoScope is the repositories on the connected Forgejo at root that a list reads, owner/repo
// as Forgejo names them, each with a folder to act from (by its name in lower case), and the
// connection read with root.
type forgejoScope struct {
	root     string
	conn     connections.Connection
	repos    []string
	folderOf map[string]string
}

func (s forgejoScope) Key() []any  { return []any{s.root, s.repos} }
func (s forgejoScope) Empty() bool { return len(s.repos) == 0 }

// Sources is the repositories of folders on the connected Forgejo, each once: a folder whose
// remote is neither GitHub's nor GitLab's. Its token is for nowhere else: when no folder is on
// it and some are on another Forgejo, err says so.
func (g forgejoForge) Sources(ctx context.Context, folders []string, _ bool) (forgeScope, error) {
	c, root := g.d.forgejoRoot()
	s := forgejoScope{root: root, conn: c, folderOf: map[string]string{}}
	elsewhere := false
	for _, f := range folders {
		if onGitHubOrGitLab(g.d.folderRepo(f)) {
			continue
		}
		at, repo := g.d.forgejoRepoAt(ctx, f, c.URL)
		if repo == "" {
			continue
		}
		if _, seen := s.folderOf[strings.ToLower(repo)]; seen {
			continue
		}
		if root == "" || at != root {
			elsewhere = true
			continue
		}
		s.folderOf[strings.ToLower(repo)] = f
		s.repos = append(s.repos, repo)
	}
	slices.Sort(s.repos)
	if len(s.repos) > 0 || !elsewhere {
		return s, nil
	}
	// A page still says why Forgejo's folders are not in it.
	if root != "" {
		return s, errors.New("Forgejo is connected at " + root + ", and no folder here is on it")
	}
	return s, errors.New(forgejomcp.NotConnected)
}

// List is a call for each repository, as Forgejo has no list across chosen repositories. Forgejo
// has project boards, but its API cannot read them, so a board's list has no Forgejo items (#3835).
func (g forgejoForge) List(ctx context.Context, scope forgeScope, f forgeFilter, cursor string, limit int) (forgePage, error) {
	s, _ := scope.(forgejoScope)
	if f.Board != nil || s.Empty() {
		return forgePage{}, nil
	}
	sf := forgejomcp.SearchFilter{PRs: f.PRs, State: f.State, Label: f.Label, Assignee: f.Assignee, Query: f.Query, Feature: f.Feature}
	page, err := g.d.forgeForgejo(s.conn, s.root).Search(ctx, s.repos, sf, cursor, limit)
	var p forgePage
	for _, i := range page.Items {
		p.items = append(p.items, forgejoItemOf(i, s.folderOf[strings.ToLower(i.Repo)]))
	}
	p.cursors, p.next = page.Cursors, page.Next
	return p, err
}

// of is the connected Forgejo, r's repository as Forgejo names it, and a folder on it.
func (g forgejoForge) of(ctx context.Context, method string, r forgeRef) (forgeForgejo, string, string, error) {
	return g.d.forgejoOf(ctx, method, r.Repo)
}

func (g forgejoForge) Item(ctx context.Context, r forgeRef, cursor string) (wire.ForgeItemDetail, error) {
	method := itemMethod(r.Node.Kind)
	fj, named, folder, err := g.of(ctx, method, r)
	if err != nil {
		return wire.ForgeItemDetail{}, err
	}
	p, err := fj.ItemPage(ctx, named, r.Number, r.pr(), cursor)
	if err != nil {
		if forgejomcp.IsNotFound(err) {
			return wire.ForgeItemDetail{}, Invalid("%s: %v", method, err)
		}
		return wire.ForgeItemDetail{}, err
	}
	out := wire.ForgeItemDetail{Item: forgejoItemOf(p.Item, folder), Body: p.Body, Comments: []wire.ForgeComment{}, Cursor: optional(p.Before)}
	for _, c := range p.Thread {
		out.Comments = append(out.Comments, forgeCommentOf(c.Author, c.Avatar, c.Body, c.At, c.URL, c.Bot))
	}
	if !p.PR {
		out.Start = forgejoStart(out.Item, r.Number)
		return out, nil
	}
	out.Checks = []wire.ForgeCheck{}
	for _, c := range p.CheckRuns {
		out.Checks = append(out.Checks, wire.ForgeCheck{Name: c.Name, State: c.State, URL: optional(c.URL)})
	}
	out.ReviewThreads, out.FilesChanged = new(int64(p.ReviewThreads)), new(int64(p.FilesChanged))
	out.Head = optional(p.Head)
	// The merge menu is a nicety: a page still reads when Forgejo does not say the repository's.
	if methods, err := fj.MergeMethods(ctx, named); err == nil {
		out.MergeMethods = mergeMethodsOf(methods)
	}
	return out, nil
}

// Labels are the repository's labels, with their colours.
func (g forgejoForge) Labels(ctx context.Context, r forgeRef) ([]wire.ForgeLabel, error) {
	fj, named, _, err := g.of(ctx, "forge/labels", r)
	if err != nil {
		return nil, err
	}
	names, colors, err := fj.RepoLabels(ctx, named)
	if err != nil {
		return nil, err
	}
	return forgeLabelsOf(names, colors), nil
}

// Plan is a Forgejo epic and its children, the issues it depends on (#3835), each blocked by the
// issues it depends on. The children say the epic is their parent, and the epic says how many of
// them are done.
func (g forgejoForge) Plan(ctx context.Context, r forgeRef) (forgePlanAnswer, error) {
	const method = "forge/plan"
	fj, named, folder, err := g.of(ctx, method, r)
	if err != nil {
		return forgePlanAnswer{}, err
	}
	p, err := fj.Plan(ctx, named, r.Number)
	if err != nil {
		if forgejomcp.IsNotFound(err) {
			return forgePlanAnswer{}, Invalid("%s: %v", method, err)
		}
		return forgePlanAnswer{}, err
	}
	out := forgePlanAnswer{epic: forgejoItemOf(p.Epic, folder)}
	done := 0
	for _, c := range p.Children {
		item := forgejoItemOf(c.Item, g.d.forgejoFolder(ctx, c.Repo, named, folder))
		item.Parent = new(out.epic.Node)
		if item.State == "closed" {
			done++
		}
		pc := planChild{item: item}
		for _, b := range c.BlockedBy {
			pc.blockedBy = append(pc.blockedBy, planRef{node: forgejoNode(b.Repo, b.Number, b.PR), open: b.Open})
		}
		out.children = append(out.children, pc)
	}
	withHierarchy(&out.epic, nil, len(out.children), done)
	return out, nil
}

// Blockers is a read for each repository the children are on (the epic's own, as a rule), which
// reads a child's at a time.
func (g forgejoForge) Blockers(ctx context.Context, children []forgeRef) (map[forgeRef][]planRef, error) {
	out := map[forgeRef][]planRef{}
	byRepo := map[string][]forgeRef{}
	var repos []string
	for _, c := range children {
		if _, seen := byRepo[c.Repo]; !seen {
			repos = append(repos, c.Repo)
		}
		byRepo[c.Repo] = append(byRepo[c.Repo], c)
	}
	for _, repo := range repos {
		fj, named, _, err := g.of(ctx, "forge/plan", byRepo[repo][0])
		if err != nil {
			return nil, err
		}
		numbers := make([]int, len(byRepo[repo]))
		for n, c := range byRepo[repo] {
			numbers[n] = c.Number
		}
		by, err := fj.Blockers(ctx, named, numbers)
		if err != nil {
			return nil, err
		}
		for _, c := range byRepo[repo] {
			for _, b := range by[c.Number] {
				out[c] = append(out[c], planRef{node: forgejoNode(b.Repo, b.Number, b.PR), open: b.Open})
			}
		}
	}
	return out, nil
}

func (g forgejoForge) Diff(ctx context.Context, r forgeRef) (wire.ForgeDiff, error) {
	if !r.pr() {
		return wire.ForgeDiff{}, cannot(actionDiff)
	}
	fj, named, _, err := g.of(ctx, "forge/diff", r)
	if err != nil {
		return wire.ForgeDiff{}, err
	}
	out, err := fj.PRDiff(ctx, named, r.Number)
	if err != nil {
		return wire.ForgeDiff{}, err
	}
	return diffOf(out)
}

func (g forgejoForge) Comment(ctx context.Context, r forgeRef, body string) (wire.ForgeDone, error) {
	fj, named, _, err := g.of(ctx, "forge/comment", r)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	link, err := fj.Comment(ctx, named, r.Number, body)
	return wire.ForgeDone{URL: optional(link)}, err
}

func (g forgejoForge) SetLabels(ctx context.Context, r forgeRef, add, remove []string) error {
	fj, named, _, err := g.of(ctx, "forge/label", r)
	if err != nil {
		return err
	}
	return fj.SetLabels(ctx, named, r.Number, add, remove)
}

func (g forgejoForge) SetAssignees(ctx context.Context, r forgeRef, add, remove []string) error {
	fj, named, _, err := g.of(ctx, "forge/assign", r)
	if err != nil {
		return err
	}
	return fj.SetAssignees(ctx, named, r.Number, add, remove)
}

func (g forgejoForge) SetState(ctx context.Context, r forgeRef, closed bool, transition string) error {
	if transition != "" {
		return cannot(actionTransition)
	}
	fj, named, _, err := g.of(ctx, "forge/close", r)
	if err != nil {
		return err
	}
	return fj.SetState(ctx, named, r.Number, closed)
}

// Merge merges a pull request by the method asked for, or the repository's default.
func (g forgejoForge) Merge(ctx context.Context, r forgeRef, sha, how string, auto bool) (wire.ForgeDone, error) {
	const method = "forge/merge"
	if !r.pr() {
		return wire.ForgeDone{}, cannot(actionMerge)
	}
	fj, named, _, err := g.of(ctx, method, r)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	methods, err := fj.MergeMethods(ctx, named)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	if len(methods) == 0 {
		return wire.ForgeDone{}, Invalid("%s: %s allows no merge method", method, named)
	}
	if how == "" {
		how = methods[0]
	}
	if !slices.Contains(methods, how) {
		return wire.ForgeDone{}, Invalid("%s: this repository merges by %s", method, strings.Join(methods, " or "))
	}
	if err := fj.Merge(ctx, named, r.Number, sha, how, auto); err != nil {
		return wire.ForgeDone{}, err
	}
	return wire.ForgeDone{Auto: optionalTrue(auto)}, nil
}

func (g forgejoForge) CancelAutoMerge(ctx context.Context, r forgeRef) error {
	if !r.pr() {
		return cannot(actionCancelAuto)
	}
	fj, named, _, err := g.of(ctx, "forge/cancel-auto-merge", r)
	if err != nil {
		return err
	}
	return fj.CancelAutoMerge(ctx, named, r.Number)
}

func (g forgejoForge) Ready(ctx context.Context, r forgeRef) error {
	if !r.pr() {
		return cannot(actionReady)
	}
	fj, named, _, err := g.of(ctx, "forge/ready", r)
	if err != nil {
		return err
	}
	return fj.MarkReady(ctx, named, r.Number)
}

func (g forgejoForge) Approve(ctx context.Context, r forgeRef, sha string) (wire.ForgeDone, error) {
	if !r.pr() {
		return wire.ForgeDone{}, cannot(actionApprove)
	}
	fj, named, _, err := g.of(ctx, "forge/approve", r)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	link, err := fj.Approve(ctx, named, r.Number, sha)
	return wire.ForgeDone{URL: optional(link)}, err
}

// AddChild makes a new issue in the epic's repository, or takes the issue that child.Issue names
// (#12, owner/repo#12 or its URL on the connected Forgejo), and makes the epic depend on it: a
// Forgejo epic's children are the issues it depends on.
func (g forgejoForge) AddChild(ctx context.Context, epic forgeRef, child forgeChild) (wire.ForgeDone, error) {
	const method = "forge/add-child"
	fj, named, _, err := g.of(ctx, method, epic)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	if child.Issue == "" {
		n, link, err := fj.CreateIssue(ctx, named, child.Title, child.Labels)
		if err == nil {
			err = fj.SetBlockedBy(ctx, named, epic.Number, named, n, true)
		}
		return wire.ForgeDone{URL: optional(link)}, err
	}
	repo, n, ok := g.d.forgejoIssueOf(child.Issue, named)
	if !ok {
		return wire.ForgeDone{}, Invalid("%s: %q is not an issue on the connected Forgejo: give #12, owner/repo#12 or its URL", method, child.Issue)
	}
	if forgejoNode(repo, n, false) == epic.Node {
		return wire.ForgeDone{}, Invalid("%s: an epic is not its own child", method)
	}
	return wire.ForgeDone{}, fj.SetBlockedBy(ctx, named, epic.Number, repo, n, true)
}

func (g forgejoForge) SetBlockedBy(ctx context.Context, r, blocker forgeRef, blocked bool) error {
	fj, named, _, err := g.of(ctx, "forge/blocked-by", r)
	if err != nil {
		return err
	}
	return fj.SetBlockedBy(ctx, named, r.Number, blocker.Repo, blocker.Number, blocked)
}

// forgejoOf is the connected Forgejo, repo as Forgejo says it, and a folder on it: a node names
// the repository only, so a folder on it says which Forgejo that is.
func (d *Daemon) forgejoOf(ctx context.Context, method, repo string) (forgeForgejo, string, string, error) {
	c, root := d.forgejoRoot()
	if root == "" {
		return nil, "", "", errors.New(forgejomcp.NotConnected)
	}
	for _, f := range d.folderPaths() {
		if onGitHubOrGitLab(d.folderRepo(f)) {
			continue
		}
		if at, named := d.forgejoRepoAt(ctx, f, c.URL); at == root && strings.EqualFold(named, repo) {
			return d.forgeForgejo(c, root), named, f, nil
		}
	}
	return nil, "", "", Invalid("%s: no folder here is on %s on the connected Forgejo, %s", method, repo, root)
}

// forgeForgejo is the Forgejo at root as connection c, which the caller read with root: read
// again, it may have gone in between, and the call would go with no token.
func (d *Daemon) forgeForgejo(c connections.Connection, root string) forgeForgejo {
	if d.newForgeForgejo != nil {
		return d.newForgeForgejo(root, c.Access)
	}
	token := c.Access
	return forgejomcp.NewRealForgejo(root, func() string { return token }, nil)
}

// forgejoItemOf is a Forgejo item in the one model, from folder.
func forgejoItemOf(i forgejomcp.Item, folder string) wire.ForgeItem {
	out := wire.ForgeItem{Node: forgejoNode(i.Repo, i.Number, i.PR), Title: i.Title, State: i.State, URL: optional(i.URL),
		Folder: optional(folder), Labels: forgeLabelsOf(i.Labels, i.LabelColors), Author: optional(i.Author), AuthorAvatar: optional(i.AuthorAvatar), Assignees: i.Assignees,
		Milestone: optional(i.Milestone), UpdatedAt: forgeDate(i.UpdatedAt), CreatedAt: forgeDateOptional(i.CreatedAt), ClosedAt: forgeDateOptional(i.ClosedAt), Comments: int64(i.Comments)}
	if out.Assignees == nil {
		out.Assignees = []string{}
	}
	if i.PR {
		out.Draft, out.AutoMerge = new(i.Draft), new(i.AutoMerge)
		out.Checks, out.Review, out.Mergeable = optional(i.Checks), optional(i.Review), optional(i.Mergeable)
		withPullRefs(&out, i.HeadRef, i.BaseRef, i.MergedBy, i.MergeCommit)
		return out
	}
	// An issue's level and feature are its labels'; Forgejo has no parent, and a list does not
	// read an epic's children (forgejoForge.Plan does).
	withHierarchy(&out, nil, 0, 0)
	return out
}

// forgejoFolder is the folder of repo on the connected Forgejo: folder when repo is the epic's
// own (named), else the folder a list would give it, if any.
func (d *Daemon) forgejoFolder(ctx context.Context, repo, named, folder string) string {
	if strings.EqualFold(repo, named) {
		return folder
	}
	c, root := d.forgejoRoot()
	for _, f := range d.folderPaths() {
		if onGitHubOrGitLab(d.folderRepo(f)) {
			continue
		}
		if at, r := d.forgejoRepoAt(ctx, f, c.URL); at == root && strings.EqualFold(r, repo) {
			return f
		}
	}
	return ""
}

// forgejoStart is the new-agent form's prompt for a Forgejo issue.
func forgejoStart(i wire.ForgeItem, n int) *wire.ForgeStart {
	return &wire.ForgeStart{Prompt: fmt.Sprintf("#%d: %s\n\nWork on this Forgejo issue: %s", n, i.Title, deref(i.URL)),
		Labels: []string{"#" + strconv.Itoa(n)}, Worktree: optional(strconv.Itoa(n) + " " + i.Title)}
}
