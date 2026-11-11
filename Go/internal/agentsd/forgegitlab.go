package agentsd

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"slices"
	"strings"

	"github.com/alexec/agents/Go/internal/gitlabmcp"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// gitlabForge is GitLab on the forge interface (#4329, #4353): the host's GitLab connection,
// only on its own GitLab, through the gitlab connector's own client (forgeGitLab). A node names
// its project's path only, so a folder on it says which GitLab that is (gitlabOf). The parents of
// a standing epic's issues (Parents) stay on forgeGitLab, which forgestanding.go asks with
// gitlabOf. A GitLab plan is read here but changed on GitLab: its links are Premium only.
type gitlabForge struct {
	forgeNone
	d *Daemon
}

// gitlabNoPlanWrite is why a GitLab plan is not changed here.
const gitlabNoPlanWrite = "a GitLab plan is changed on GitLab, not yet here"

func (gitlabForge) Name() string { return "gitlab" }

func (gitlabForge) Images() forgeImageHost { return gitlabImages{} }

func (gitlabForge) Caps() forgeCaps {
	return forgeCaps{
		Issues: true, PRs: true,
		Issue: forgeActions{Comment: true, Label: true, Assign: true, Close: true, Reopen: true},
		PR: forgeActions{Comment: true, Label: true, Assign: true, Close: true, Reopen: true, Merge: true, AutoMerge: true, Approve: true,
			Rerun: true, Log: true, Diff: true},
		LabelColors: true,
		Avatars:     true,
		CreatedAt:   true, ClosedAt: true,
		// A pull request's branches and merge (#4409); its size, reviewers, closing issues and check times are #4682.
		Branches: true, MergedBy: true, MergeCommit: true,
		CommentCount: "exact",
		Releases:     true,
		// X-Total, which GitLab leaves out of a list of over 10,000.
		Total: true,
		Plan:  true,
		Reasons: map[string]string{
			actionTransition: "only a Jira issue or an Azure Boards work item moves by a transition",
			actionAddChild:   gitlabNoPlanWrite,
			actionBlockedBy:  gitlabNoPlanWrite,
		},
	}
}

// Owns is gitlab:group/project#12 or gitlab:group/project!4.
func (gitlabForge) Owns(node wire.LineageNode) (forgeRef, bool) {
	if node.Kind != lineage.KindIssue && node.Kind != lineage.KindPR {
		return forgeRef{}, false
	}
	repo, number, ok := nodeOfRepo(node)
	if !ok || repo.forge != "gitlab" {
		return forgeRef{}, false
	}
	return forgeRef{Node: node, Repo: repo.path, Number: number}, true
}

// gitlabScope is the projects on the connected GitLab at root that a list reads, as GitLab
// names them, each with a folder to act from (by its path in lower case).
type gitlabScope struct {
	root     string
	projects []string
	folderOf map[string]string
}

func (s gitlabScope) Key() []any  { return []any{s.root, s.projects} }
func (s gitlabScope) Empty() bool { return len(s.projects) == 0 }

// Sources is the folders' projects on the connected GitLab, each once: its token is for nowhere
// else. When no folder is on it and some are on another GitLab, err says so.
func (g gitlabForge) Sources(ctx context.Context, folders []string, _ bool) (forgeScope, error) {
	s := gitlabScope{folderOf: map[string]string{}}
	gl, connected := g.d.gitlabConnection()
	if connected && gl.Usable(nowFunc()) {
		s.root = gitlabmcp.BaseURL(gl.URL)
	}
	elsewhere := false
	for _, f := range folders {
		repo := g.d.folderRepo(f)
		if _, seen := s.folderOf[repo.path]; repo.forge != "gitlab" || repo.path == "" || seen {
			continue
		}
		if root, project := g.d.gitlabProjectAt(ctx, f, gl.URL); s.root != "" && root == s.root {
			s.folderOf[repo.path] = f
			s.projects = append(s.projects, project)
		} else {
			elsewhere = true
		}
	}
	slices.Sort(s.projects)
	if len(s.projects) > 0 || !elsewhere {
		return s, nil
	}
	// A page still says why GitLab's folders are not in it.
	if s.root != "" {
		return s, errors.New("GitLab is connected at " + s.root + ", and no folder here is on it")
	}
	return s, errors.New(gitlabmcp.NotConnected)
}

// List is a call for each project, as GitLab has no list across chosen projects. A board's list
// is of its group's projects on the connected GitLab, in the board's scope.
func (g gitlabForge) List(ctx context.Context, scope forgeScope, f forgeFilter, cursor string, limit int) (forgePage, error) {
	s, _ := scope.(gitlabScope)
	sf := gitlabmcp.SearchFilter{MRs: f.PRs, State: f.State, Label: f.Label, Assignee: f.Assignee, Query: f.Query, Feature: f.Feature}
	projects := s.projects
	gl := g.d.forgeGitLab(s.root)
	if b := f.Board; b != nil {
		projects = nil
		// Only a board on the connected GitLab: its token is for nowhere else.
		if root, err := url.Parse(s.root); err == nil && s.root != "" && strings.EqualFold(root.Host, b.site) {
			for _, project := range s.projects {
				if strings.HasPrefix(strings.ToLower(project), strings.ToLower(b.group)+"/") {
					projects = append(projects, project)
				}
			}
		}
		if len(projects) == 0 {
			return forgePage{}, nil
		}
		var err error
		if sf.Board, err = gl.GroupBoard(ctx, b.group, b.id); err != nil {
			return forgePage{}, err
		}
	}
	page, err := gl.Search(ctx, projects, sf, cursor, limit)
	var p forgePage
	for _, i := range page.Items {
		p.items = append(p.items, gitlabItemOf(i, s.folderOf[strings.ToLower(i.Project)]))
	}
	p.cursors, p.next, p.total = page.Cursors, page.Next, page.Total
	return p, err
}

// of is the connected GitLab, r's project there and a folder on it.
func (g gitlabForge) of(ctx context.Context, method string, r forgeRef) (forgeGitLab, string, string, error) {
	return g.d.gitlabOf(ctx, method, forgeRepo{"gitlab", r.Repo})
}

func (g gitlabForge) Item(ctx context.Context, r forgeRef, cursor string) (wire.ForgeItemDetail, error) {
	method := itemMethod(r.Node.Kind)
	gl, project, folder, err := g.of(ctx, method, r)
	if err != nil {
		return wire.ForgeItemDetail{}, err
	}
	p, err := gl.ItemPage(ctx, project, r.Number, r.pr(), cursor)
	if err != nil {
		if gitlabmcp.IsNotFound(err) {
			return wire.ForgeItemDetail{}, Invalid("%s: %v", method, err)
		}
		return wire.ForgeItemDetail{}, err
	}
	out := wire.ForgeItemDetail{Item: gitlabItemOf(p.Item, folder), Body: p.Body, Comments: []wire.ForgeComment{}}
	for _, c := range p.Thread {
		out.Comments = append(out.Comments, forgeCommentOf(c.Author, c.Avatar, c.Body, c.At, c.URL, c.Bot))
	}
	out.Cursor = optional(p.Before)
	if p.MR {
		out.Checks = []wire.ForgeCheck{}
		for _, c := range p.CheckRuns {
			out.Checks = append(out.Checks, wire.ForgeCheck{Name: c.Name, State: c.State, URL: optional(c.URL)})
		}
		out.ReviewThreads, out.FilesChanged = new(int64(p.ReviewThreads)), new(int64(p.FilesChanged))
		out.Head = optional(p.Head)
		// The merge menu is a nicety: a page still reads when GitLab does not say the project's.
		if methods, err := gl.MergeMethods(ctx, project); err == nil {
			out.MergeMethods = mergeMethodsOf(methods)
		}
	} else {
		out.Start = gitlabStart(out.Item)
	}
	return out, nil
}

// Labels are the project's labels, with their colours.
func (g gitlabForge) Labels(ctx context.Context, r forgeRef) ([]wire.ForgeLabel, error) {
	gl, project, _, err := g.of(ctx, "forge/labels", r)
	if err != nil {
		return nil, err
	}
	names, colors, err := gl.ProjectLabels(ctx, project)
	if err != nil {
		return nil, err
	}
	return forgeLabelsOf(names, colors), nil
}

// Plan is the epic's child issues, each blocked by the issues its links say.
func (g gitlabForge) Plan(ctx context.Context, r forgeRef) (forgePlanAnswer, error) {
	const method = "forge/plan"
	gl, project, folder, err := g.of(ctx, method, r)
	if err != nil {
		return forgePlanAnswer{}, err
	}
	p, err := gl.Plan(ctx, project, r.Number)
	if err != nil {
		if gitlabmcp.IsNotFound(err) {
			return forgePlanAnswer{}, Invalid("%s: %v", method, err)
		}
		return forgePlanAnswer{}, err
	}
	out := forgePlanAnswer{epic: gitlabItemOf(p.Epic, folder)}
	for _, c := range p.Children {
		child := forgeRepo{"gitlab", strings.ToLower(c.Project)}
		pc := planChild{item: gitlabItemOf(c.Item, g.d.repoFolder(child))}
		for _, b := range c.BlockedBy {
			pc.blockedBy = append(pc.blockedBy, planRef{node: forgeRepo{"gitlab", strings.ToLower(b.Project)}.issue(b.Number), open: b.Open})
		}
		out.children = append(out.children, pc)
	}
	return out, nil
}

// Blockers is one GraphQL read for each project the children are on (the epic's own, as a rule).
func (g gitlabForge) Blockers(ctx context.Context, children []forgeRef) (map[forgeRef][]planRef, error) {
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
		gl, project, _, err := g.of(ctx, "forge/plan", byRepo[repo][0])
		if err != nil {
			return nil, err
		}
		numbers := make([]int, len(byRepo[repo]))
		for n, c := range byRepo[repo] {
			numbers[n] = c.Number
		}
		by, err := gl.Blockers(ctx, project, numbers)
		if err != nil {
			return nil, err
		}
		for _, c := range byRepo[repo] {
			for _, b := range by[c.Number] {
				out[c] = append(out[c], planRef{node: forgeRepo{"gitlab", strings.ToLower(b.Project)}.issue(b.Number), open: b.Open})
			}
		}
	}
	return out, nil
}

func (g gitlabForge) Diff(ctx context.Context, r forgeRef) (wire.ForgeDiff, error) {
	if !r.pr() {
		return wire.ForgeDiff{}, cannot(actionDiff)
	}
	gl, project, _, err := g.of(ctx, "forge/diff", r)
	if err != nil {
		return wire.ForgeDiff{}, err
	}
	out, err := gl.MRDiff(ctx, project, r.Number)
	if err != nil {
		return wire.ForgeDiff{}, err
	}
	return diffOf(out)
}

// Log is the failed jobs' logs of the merge request's pipeline, or of the one check named.
func (g gitlabForge) Log(ctx context.Context, r forgeRef, check string) (wire.ForgeLog, error) {
	const method = "forge/log"
	if !r.pr() {
		return wire.ForgeLog{}, cannot(actionLog)
	}
	gl, project, _, err := g.of(ctx, method, r)
	if err != nil {
		return wire.ForgeLog{}, err
	}
	p, err := gl.ItemPage(ctx, project, r.Number, true, "")
	if err != nil {
		return wire.ForgeLog{}, err
	}
	if p.Pipeline == 0 {
		return wire.ForgeLog{}, Invalid("%s: %s has no pipeline", method, r.Node.Ref)
	}
	// A GitLab check is "stage: job"; its log is the job's.
	if _, job, ok := strings.Cut(check, ": "); ok {
		check = job
	}
	text, err := gl.FailedLog(ctx, project, p.Pipeline, check)
	return wire.ForgeLog{Text: text}, err
}

func (g gitlabForge) Comment(ctx context.Context, r forgeRef, body string) (wire.ForgeDone, error) {
	gl, project, _, err := g.of(ctx, "forge/comment", r)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	return wire.ForgeDone{}, gl.Comment(ctx, project, r.Number, r.pr(), body)
}

func (g gitlabForge) SetLabels(ctx context.Context, r forgeRef, add, remove []string) error {
	gl, project, _, err := g.of(ctx, "forge/label", r)
	if err != nil {
		return err
	}
	return gl.SetLabels(ctx, project, r.Number, r.pr(), add, remove)
}

func (g gitlabForge) SetAssignees(ctx context.Context, r forgeRef, add, remove []string) error {
	gl, project, _, err := g.of(ctx, "forge/assign", r)
	if err != nil {
		return err
	}
	return gl.SetAssignees(ctx, project, r.Number, r.pr(), add, remove)
}

func (g gitlabForge) SetState(ctx context.Context, r forgeRef, closed bool, transition string) error {
	if transition != "" {
		return cannot(actionTransition)
	}
	gl, project, _, err := g.of(ctx, "forge/close", r)
	if err != nil {
		return err
	}
	return gl.SetState(ctx, project, r.Number, r.pr(), closed)
}

// Merge merges at sha by method, or by the project's first when none is said.
func (g gitlabForge) Merge(ctx context.Context, r forgeRef, sha, how string, auto bool) (wire.ForgeDone, error) {
	const method = "forge/merge"
	if !r.pr() {
		return wire.ForgeDone{}, cannot(actionMerge)
	}
	gl, project, _, err := g.of(ctx, method, r)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	methods, err := gl.MergeMethods(ctx, project)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	if how == "" {
		how = methods[0]
	}
	if !slices.Contains(methods, how) {
		return wire.ForgeDone{}, Invalid("%s: this project merges by %s", method, strings.Join(methods, " or "))
	}
	if err := gl.Merge(ctx, project, r.Number, sha, how == "squash", auto); err != nil {
		return wire.ForgeDone{}, err
	}
	return wire.ForgeDone{Auto: optionalTrue(auto)}, nil
}

func (g gitlabForge) Approve(ctx context.Context, r forgeRef, sha string) (wire.ForgeDone, error) {
	if !r.pr() {
		return wire.ForgeDone{}, cannot(actionApprove)
	}
	gl, project, _, err := g.of(ctx, "forge/approve", r)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	_, err = gl.Approve(ctx, project, r.Number, sha)
	return wire.ForgeDone{}, err
}

// Rerun retries the merge request's pipeline.
func (g gitlabForge) Rerun(ctx context.Context, r forgeRef) (wire.ForgeDone, error) {
	const method = "forge/rerun"
	if !r.pr() {
		return wire.ForgeDone{}, cannot(actionRerun)
	}
	gl, project, _, err := g.of(ctx, method, r)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	p, err := gl.ItemPage(ctx, project, r.Number, true, "")
	if err != nil {
		return wire.ForgeDone{}, err
	}
	if p.Pipeline == 0 {
		return wire.ForgeDone{}, Invalid("%s: %s has no pipeline to retry", method, r.Node.Ref)
	}
	out, err := gl.RetryPipeline(ctx, project, p.Pipeline)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	link, _ := out["url"].(string)
	return wire.ForgeDone{URL: optional(link), Reran: new(int64(1))}, nil
}

// gitlabStart is the new-agent form's prompt for a GitLab issue.
func gitlabStart(i wire.ForgeItem) *wire.ForgeStart {
	_, n, ok := nodeOfRepo(i.Node)
	if !ok {
		return nil
	}
	return numberedStart(fmt.Sprintf("#%d: %s\n\nWork on this GitLab issue: %s", n, i.Title, deref(i.URL)), n, i.Title)
}
