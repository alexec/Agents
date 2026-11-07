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
// request's page sends those to Forgejo's own page.

// forgeForgejo is what the forge reads and writes ask of Forgejo; a test gives a fake.
type forgeForgejo interface {
	Search(ctx context.Context, repos []string, f forgejomcp.SearchFilter, after string, first int) (forgejomcp.SearchPage, error)
	ItemPage(ctx context.Context, repo string, number int, pr bool, before string) (forgejomcp.ItemDetail, error)
	Comment(ctx context.Context, repo string, number int, body string) (string, error)
	SetLabels(ctx context.Context, repo string, number int, add, remove []string) error
	SetState(ctx context.Context, repo string, number int, closed bool) error
	RepoLabels(ctx context.Context, repo string) ([]string, map[string]string, error)
	MergeMethods(ctx context.Context, repo string) ([]string, error)
	Merge(ctx context.Context, repo string, number int, sha, method string, auto bool) error
	Approve(ctx context.Context, repo string, number int, sha string) (string, error)
	PRDiff(ctx context.Context, repo string, number int) (map[string]any, error)
	Plan(ctx context.Context, repo string, number int) (forgejomcp.Plan, error)
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

// forgejoSources adds to s the repositories of folders on the connected Forgejo: a folder whose
// remote is neither GitHub's nor GitLab's. A Forgejo folder elsewhere leaves a reason.
func (d *Daemon) forgejoSources(ctx context.Context, s *forgeSources, folders []string) {
	c, root := d.forgejoRoot()
	s.forgejoRoot = root
	elsewhere := false
	for _, f := range folders {
		if d.folderRepo(f).forge != "" {
			continue
		}
		at, repo := d.forgejoRepoAt(ctx, f, c.URL)
		if repo == "" {
			continue
		}
		key := forgeRepo{"forgejo", strings.ToLower(repo)}
		if _, seen := s.folderOf[key]; seen {
			continue
		}
		if root == "" || at != root {
			elsewhere = true
			continue
		}
		s.folderOf[key] = f
		s.forgejo = append(s.forgejo, repo)
	}
	slices.Sort(s.forgejo)
	if len(s.forgejo) == 0 && elsewhere {
		s.forgejoErr = errors.New(forgejomcp.NotConnected)
		if root != "" {
			s.forgejoErr = errors.New("Forgejo is connected at " + root + ", and no folder here is on it")
		}
	}
}

// forgejoPage is the Forgejo page of a list.
func (d *Daemon) forgejoPage(ctx context.Context, s forgeSources, f forgejomcp.SearchFilter, after string, limit int) forgePage {
	p := forgePage{forge: "forgejo", err: s.forgejoErr}
	if p.err != nil {
		return p
	}
	page, err := d.forgeForgejo(s.forgejoRoot).Search(ctx, s.forgejo, f, after, limit)
	for _, i := range page.Items {
		p.items = append(p.items, forgejoItemOf(i, s.folderOf[forgeRepo{"forgejo", strings.ToLower(i.Repo)}]))
	}
	p.cursors, p.next, p.err = page.Cursors, page.Next, err
	return p
}

// forgejoOf is the connected Forgejo, repo as Forgejo says it, and a folder on it: a node names
// the repository only, so a folder on it says which Forgejo that is.
func (d *Daemon) forgejoOf(ctx context.Context, method, repo string) (forgeForgejo, string, string, error) {
	c, root := d.forgejoRoot()
	if root == "" {
		return nil, "", "", errors.New(forgejomcp.NotConnected)
	}
	for _, f := range d.folderPaths() {
		if d.folderRepo(f).forge != "" {
			continue
		}
		if at, named := d.forgejoRepoAt(ctx, f, c.URL); at == root && strings.EqualFold(named, repo) {
			return d.forgeForgejo(root), named, f, nil
		}
	}
	return nil, "", "", Invalid("%s: no folder here is on %s on the connected Forgejo, %s", method, repo, root)
}

// forgeForgejo is the Forgejo at root as the person's connection; the caller has checked there is one.
func (d *Daemon) forgeForgejo(root string) forgeForgejo {
	c, _ := d.forgejoConnection()
	if d.newForgeForgejo != nil {
		return d.newForgeForgejo(root, c.Access)
	}
	token := c.Access
	return forgejomcp.NewRealForgejo(root, func() string { return token }, nil)
}

// forgejoItem is an issue or pull request on the connected Forgejo.
func (d *Daemon) forgejoItem(ctx context.Context, method, kind, repo string, number int, cursor string) (wire.ForgeItemDetail, error) {
	fj, named, folder, err := d.forgejoOf(ctx, method, repo)
	if err != nil {
		return wire.ForgeItemDetail{}, err
	}
	p, err := fj.ItemPage(ctx, named, number, kind == lineage.KindPR, cursor)
	if err != nil {
		if forgejomcp.IsNotFound(err) {
			return wire.ForgeItemDetail{}, Invalid("%s: %v", method, err)
		}
		return wire.ForgeItemDetail{}, err
	}
	out := wire.ForgeItemDetail{Item: forgejoItemOf(p.Item, folder), Body: p.Body, Comments: []wire.ForgeComment{}, Cursor: optional(p.Before)}
	for _, c := range p.Thread {
		out.Comments = append(out.Comments, forgeCommentOf(c.Author, c.Body, c.At, c.URL, c.Bot))
	}
	if !p.PR {
		out.Start = forgeStartOf(out.Item)
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

// forgejoItemOf is a Forgejo item in the one model, from folder.
func forgejoItemOf(i forgejomcp.Item, folder string) wire.ForgeItem {
	out := wire.ForgeItem{Node: forgejoNode(i.Repo, i.Number, i.PR), Title: i.Title, State: i.State, URL: optional(i.URL),
		Folder: optional(folder), Labels: forgeLabelsOf(i.Labels, i.LabelColors), Author: optional(i.Author), Assignees: i.Assignees,
		Milestone: optional(i.Milestone), UpdatedAt: forgeDate(i.UpdatedAt), Comments: int64(i.Comments)}
	if out.Assignees == nil {
		out.Assignees = []string{}
	}
	if i.PR {
		out.Draft, out.AutoMerge = new(i.Draft), new(i.AutoMerge)
		out.Checks, out.Review, out.Mergeable = optional(i.Checks), optional(i.Review), optional(i.Mergeable)
		return out
	}
	// An issue's level and feature are its labels'; Forgejo has no parent, and a list does not
	// read an epic's children (forgejoPlan does).
	withHierarchy(&out, nil, 0, 0)
	return out
}

// forgejoPlan is a Forgejo epic and its children, the issues it depends on (#3835), each blocked
// by the issues it depends on. The children say the epic is their parent, and the epic says how
// many of them are done.
func (d *Daemon) forgejoPlan(ctx context.Context, method, repo string, number int) (wire.ForgeItem, []planChild, error) {
	fj, named, folder, err := d.forgejoOf(ctx, method, repo)
	if err != nil {
		return wire.ForgeItem{}, nil, err
	}
	p, err := fj.Plan(ctx, named, number)
	if err != nil {
		if forgejomcp.IsNotFound(err) {
			return wire.ForgeItem{}, nil, Invalid("%s: %v", method, err)
		}
		return wire.ForgeItem{}, nil, err
	}
	epic := forgejoItemOf(p.Epic, folder)
	var children []planChild
	done := 0
	for _, c := range p.Children {
		item := forgejoItemOf(c.Item, d.forgejoFolder(ctx, c.Repo, named, folder))
		item.Parent = new(epic.Node)
		if item.State == "closed" {
			done++
		}
		pc := planChild{item: item}
		for _, b := range c.BlockedBy {
			pc.blockedBy = append(pc.blockedBy, planRef{node: forgejoNode(b.Repo, b.Number, b.PR), open: b.Open})
		}
		children = append(children, pc)
	}
	withHierarchy(&epic, nil, len(children), done)
	return epic, children, nil
}

// forgejoFolder is the folder of repo on the connected Forgejo: folder when repo is the epic's
// own (named), else the folder a list would give it, if any.
func (d *Daemon) forgejoFolder(ctx context.Context, repo, named, folder string) string {
	if strings.EqualFold(repo, named) {
		return folder
	}
	c, root := d.forgejoRoot()
	for _, f := range d.folderPaths() {
		if d.folderRepo(f).forge != "" {
			continue
		}
		if at, r := d.forgejoRepoAt(ctx, f, c.URL); at == root && strings.EqualFold(r, repo) {
			return f
		}
	}
	return ""
}

// forgejoMerge merges a pull request by the method asked for, or the repository's default.
func (d *Daemon) forgejoMerge(ctx context.Context, method string, t forgeTarget, sha, how string, auto bool) error {
	methods, err := t.forgejo.MergeMethods(ctx, t.project)
	if err != nil {
		return err
	}
	if len(methods) == 0 {
		return Invalid("%s: %s allows no merge method", method, t.project)
	}
	if how == "" {
		how = methods[0]
	}
	if !slices.Contains(methods, how) {
		return Invalid("%s: this repository merges by %s", method, strings.Join(methods, " or "))
	}
	return t.forgejo.Merge(ctx, t.project, t.number, sha, how, auto)
}

// forgejoStart is the new-agent form's prompt for a Forgejo issue.
func forgejoStart(i wire.ForgeItem, n int) *wire.ForgeStart {
	return &wire.ForgeStart{Prompt: fmt.Sprintf("#%d: %s\n\nWork on this Forgejo issue: %s", n, i.Title, deref(i.URL)),
		Labels: []string{"#" + strconv.Itoa(n)}, Worktree: optional(strconv.Itoa(n) + " " + i.Title)}
}
