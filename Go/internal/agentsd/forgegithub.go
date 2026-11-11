package agentsd

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"

	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// githubForge is GitHub on the forge interface (#4329, #4352): the host's GitHub connection
// through the github connector's own client (forgeGitHub). GitHub's other methods (deploys,
// tags, the timeline, CI settings, a new repository, a request's answer) stay on forgeGitHub,
// which the rest of the daemon still asks with d.forgeGitHub. GitHub does every operation, so it
// embeds no forgeNone.
type githubForge struct {
	d *Daemon
}

func (githubForge) Name() string { return "github" }

func (githubForge) Images() forgeImageHost { return githubImages{} }

func (githubForge) Caps() forgeCaps {
	return forgeCaps{
		Issues: true, PRs: true,
		Issue: forgeActions{Comment: true, Label: true, Close: true, Reopen: true},
		PR: forgeActions{Comment: true, Label: true, Close: true, Reopen: true, Merge: true, AutoMerge: true, Approve: true,
			Rerun: true, Log: true, Diff: true},
		LabelColors: true,
		Avatars:     true,
		StateReason: true,
		CreatedAt:   true, ClosedAt: true, Children: true, LinkedPulls: true, Events: true,
		CommentCount: "exact",
		Plan:         true, BlockedBy: true, AddChild: true,
		Reasons: map[string]string{
			actionTransition: "only a Jira issue or an Azure Boards work item moves by a transition",
		},
	}
}

// Owns is github:owner/repo#12, an issue or a pull request.
func (githubForge) Owns(node wire.LineageNode) (forgeRef, bool) {
	if node.Kind != lineage.KindIssue && node.Kind != lineage.KindPR {
		return forgeRef{}, false
	}
	repo, number, ok := nodeOfRepo(node)
	if !ok || repo.forge != "github" {
		return forgeRef{}, false
	}
	return forgeRef{Node: node, Repo: repo.path, Number: number}, true
}

// githubScope is the repos a list searches, each with a folder to act from.
type githubScope struct {
	repos    []string
	folderOf map[string]string
}

func (s githubScope) Key() []any  { return []any{s.repos} }
func (s githubScope) Empty() bool { return len(s.repos) == 0 }

func (g githubForge) Sources(_ context.Context, folders []string, _ bool) (forgeScope, error) {
	return g.scopeOf(folders), nil
}

// scopeOf is the GitHub repos the folders are on, each once, with the first folder on each.
func (g githubForge) scopeOf(folders []string) githubScope {
	s := githubScope{folderOf: map[string]string{}}
	for _, f := range folders {
		repo := g.d.folderRepo(f)
		if _, seen := s.folderOf[repo.path]; repo.forge != "github" || repo.path == "" || seen {
			continue
		}
		s.folderOf[repo.path] = f
		s.repos = append(s.repos, repo.path)
	}
	slices.Sort(s.repos)
	return s
}

// List is one search for every repo, so a list costs one GitHub call however many folders there
// are. A board's list is of its GitHub project.
func (g githubForge) List(ctx context.Context, scope forgeScope, f forgeFilter, cursor string, limit int) (forgePage, error) {
	s, _ := scope.(githubScope)
	gh, err := g.d.forgeGitHub()
	if err != nil {
		return forgePage{}, err
	}
	sf := githubmcp.SearchFilter{PRs: f.PRs, State: f.State, Label: f.Label, Assignee: f.Assignee, Query: f.Query, Feature: f.Feature}
	if f.Board != nil {
		sf.Project = f.Board.project
	}
	page, err := gh.Search(ctx, s.repos, sf, cursor, limit)
	var p forgePage
	for _, i := range page.Items {
		p.items = append(p.items, forgeItemOf(i, s.folderOf[strings.ToLower(i.Repo)]))
	}
	p.cursors, p.next = page.Cursors, page.Next
	return p, err
}

// githubNotFound is err as a method's answer: an item GitHub does not have is Invalid.
func githubNotFound(method string, err error) error {
	var ge *githubmcp.GitHubError
	if errors.As(err, &ge) && ge.Kind == githubmcp.NotFound {
		return Invalid("%s: %v", method, err)
	}
	return err
}

func (g githubForge) Item(ctx context.Context, r forgeRef, cursor string) (wire.ForgeItemDetail, error) {
	method := itemMethod(r.Node.Kind)
	gh, err := g.d.forgeGitHub()
	if err != nil {
		return wire.ForgeItemDetail{}, err
	}
	p, err := gh.ItemPage(ctx, r.Repo, r.Number, cursor)
	if err != nil {
		return wire.ForgeItemDetail{}, githubNotFound(method, err)
	}
	if p.PR != r.pr() {
		return wire.ForgeItemDetail{}, Invalid("%s: %s#%d is not %s", method, r.Repo, r.Number,
			map[string]string{lineage.KindIssue: "an issue", lineage.KindPR: "a pull request"}[r.Node.Kind])
	}
	out := wire.ForgeItemDetail{Item: forgeItemOf(p.Item, g.d.repoFolder(forgeRepo{"github", r.Repo})), Body: p.Body, Comments: []wire.ForgeComment{}}
	for _, c := range p.Thread {
		out.Comments = append(out.Comments, forgeCommentOf(c.Author, c.Avatar, c.Body, c.At, c.URL, c.Bot))
	}
	out.Cursor = optional(p.Before)
	if p.PR {
		out.Checks = []wire.ForgeCheck{}
		for _, c := range p.CheckRuns {
			out.Checks = append(out.Checks, wire.ForgeCheck{Name: c.Name, State: c.State, URL: optional(c.URL)})
		}
		out.ReviewThreads, out.FilesChanged = new(int64(p.ReviewThreads)), new(int64(p.FilesChanged))
		out.Head, out.MergeMethods = optional(p.Head), mergeMethodsOf(p.MergeMethods)
	} else {
		out.Start = githubStart(out.Item)
		out.Children, out.LinkedPulls = githubLinkedOf(p.Children), githubLinkedOf(p.LinkedPulls)
		out.Events = []wire.ForgeEvent{}
		for _, e := range p.Events {
			ev := wire.ForgeEvent{Kind: wire.ForgeEventKind(e.Kind), Actor: optional(e.Actor), At: forgeDate(e.At), Assignee: optional(e.Assignee)}
			if e.Label != "" {
				ev.Label = &wire.ForgeLabel{Name: e.Label, Color: optional(e.LabelColor)}
			}
			if e.SourceRepo != "" {
				repo := forgeRepo{"github", strings.ToLower(e.SourceRepo)}
				ev.Source = new(map[bool]wire.LineageNode{false: repo.issue(e.SourceNumber), true: repo.pr(e.SourceNumber)}[e.SourcePR])
			}
			out.Events = append(out.Events, ev)
		}
	}
	return out, nil
}

// githubLinkedOf are an issue's sub-issues or closing pull requests in the one model (#4373).
func githubLinkedOf(ls []githubmcp.Linked) []wire.ForgeLinked {
	out := []wire.ForgeLinked{}
	for _, l := range ls {
		repo := forgeRepo{"github", strings.ToLower(l.Repo)}
		node := repo.issue(l.Number)
		if l.PR {
			node = repo.pr(l.Number)
		}
		out = append(out, wire.ForgeLinked{Node: node, Title: l.Title, State: l.State, URL: optional(l.URL)})
	}
	return out
}

// Labels are the repo's labels, with their colours.
func (g githubForge) Labels(ctx context.Context, r forgeRef) ([]wire.ForgeLabel, error) {
	gh, err := g.d.forgeGitHub()
	if err != nil {
		return nil, err
	}
	names, colors, err := gh.RepoLabels(ctx, r.Repo)
	if err != nil {
		return nil, err
	}
	return forgeLabelsOf(names, colors), nil
}

// Plan is the epic's sub-issues, each blocked by the issues its dependencies say.
func (g githubForge) Plan(ctx context.Context, r forgeRef) (forgePlanAnswer, error) {
	gh, err := g.d.forgeGitHub()
	if err != nil {
		return forgePlanAnswer{}, err
	}
	p, err := gh.Plan(ctx, r.Repo, r.Number)
	if err != nil {
		return forgePlanAnswer{}, githubNotFound("forge/plan", err)
	}
	out := forgePlanAnswer{epic: forgeItemOf(p.Epic, g.d.repoFolder(forgeRepo{"github", r.Repo}))}
	for _, c := range p.Children {
		child := forgeRepo{"github", strings.ToLower(c.Repo)}
		pc := planChild{item: forgeItemOf(c.Item, g.d.repoFolder(child))}
		for _, b := range c.BlockedBy {
			pc.blockedBy = append(pc.blockedBy, planRef{node: forgeRepo{"github", strings.ToLower(b.Repo)}.issue(b.Number), open: b.Open})
		}
		out.children = append(out.children, pc)
	}
	return out, nil
}

// Blockers is one read for each repo the children are on (the epic's own, as a rule).
func (g githubForge) Blockers(ctx context.Context, children []forgeRef) (map[forgeRef][]planRef, error) {
	if len(children) == 0 {
		return nil, nil
	}
	gh, err := g.d.forgeGitHub()
	if err != nil {
		return nil, err
	}
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
		numbers := make([]int, len(byRepo[repo]))
		for n, c := range byRepo[repo] {
			numbers[n] = c.Number
		}
		by, err := gh.Blockers(ctx, repo, numbers)
		if err != nil {
			return nil, err
		}
		for _, c := range byRepo[repo] {
			for _, b := range by[c.Number] {
				out[c] = append(out[c], planRef{node: forgeRepo{"github", strings.ToLower(b.Repo)}.issue(b.Number), open: b.Open})
			}
		}
	}
	return out, nil
}

func (g githubForge) Diff(ctx context.Context, r forgeRef) (wire.ForgeDiff, error) {
	if !r.pr() {
		return wire.ForgeDiff{}, cannot(actionDiff)
	}
	gh, err := g.d.forgeGitHub()
	if err != nil {
		return wire.ForgeDiff{}, err
	}
	out, err := gh.PRDiff(ctx, r.Repo, r.Number, "")
	if err != nil {
		return wire.ForgeDiff{}, err
	}
	return diffOf(out)
}

// failedRuns reads the pull request now, not from the cache: its head may have moved.
func (g githubForge) failedRuns(ctx context.Context, gh forgeGitHub, r forgeRef, only string) ([]int, error) {
	p, err := gh.ItemPage(ctx, r.Repo, r.Number, "")
	if err != nil {
		return nil, err
	}
	var checks []forgeCheckLink
	for _, c := range p.CheckRuns {
		checks = append(checks, forgeCheckLink{c.Name, c.State, c.URL})
	}
	return failedRuns(checks, only), nil
}

// Log is the failed jobs' logs of the failing checks' Actions runs, or of the one check named.
func (g githubForge) Log(ctx context.Context, r forgeRef, check string) (wire.ForgeLog, error) {
	if !r.pr() {
		return wire.ForgeLog{}, cannot(actionLog)
	}
	gh, err := g.d.forgeGitHub()
	if err != nil {
		return wire.ForgeLog{}, err
	}
	runs, err := g.failedRuns(ctx, gh, r, check)
	if err != nil {
		return wire.ForgeLog{}, err
	}
	if len(runs) == 0 {
		return wire.ForgeLog{Text: "No failed Actions run."}, nil
	}
	var parts []string
	for _, run := range runs {
		text, err := gh.FailedLog(ctx, r.Repo, run, check)
		if err != nil {
			return wire.ForgeLog{}, err
		}
		parts = append(parts, text)
	}
	return wire.ForgeLog{Text: strings.Join(parts, "\n\n")}, nil
}

func (g githubForge) Comment(ctx context.Context, r forgeRef, body string) (wire.ForgeDone, error) {
	gh, err := g.d.forgeGitHub()
	if err != nil {
		return wire.ForgeDone{}, err
	}
	out, err := gh.CommentOnPR(ctx, r.Repo, r.Number, body)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	url, _ := out["url"].(string)
	return wire.ForgeDone{URL: optional(url)}, nil
}

func (g githubForge) SetLabels(ctx context.Context, r forgeRef, add, remove []string) error {
	gh, err := g.d.forgeGitHub()
	if err != nil {
		return err
	}
	return gh.SetLabels(ctx, r.Repo, r.Number, add, remove)
}

func (g githubForge) SetState(ctx context.Context, r forgeRef, closed bool, transition string) error {
	if transition != "" {
		return cannot(actionTransition)
	}
	gh, err := g.d.forgeGitHub()
	if err != nil {
		return err
	}
	return gh.SetState(ctx, r.Repo, r.Number, closed)
}

// Merge merges at sha by method, or by the repo's default when none is said.
func (g githubForge) Merge(ctx context.Context, r forgeRef, sha, method string, auto bool) (wire.ForgeDone, error) {
	if !r.pr() {
		return wire.ForgeDone{}, cannot(actionMerge)
	}
	gh, err := g.d.forgeGitHub()
	if err != nil {
		return wire.ForgeDone{}, err
	}
	if method == "" {
		p, err := gh.ItemPage(ctx, r.Repo, r.Number, "")
		if err != nil {
			return wire.ForgeDone{}, err
		}
		if len(p.MergeMethods) == 0 {
			return wire.ForgeDone{}, Invalid("forge/merge: %s allows no merge method", r.Repo)
		}
		method = p.MergeMethods[0]
	}
	out, err := gh.MergeBy(ctx, r.Repo, r.Number, sha, method, auto)
	if err != nil {
		return wire.ForgeDone{}, err
	}
	url, _ := out["url"].(string)
	return wire.ForgeDone{URL: optional(url), Auto: optionalTrue(auto)}, nil
}

func (g githubForge) Approve(ctx context.Context, r forgeRef, sha string) (wire.ForgeDone, error) {
	if !r.pr() {
		return wire.ForgeDone{}, cannot(actionApprove)
	}
	gh, err := g.d.forgeGitHub()
	if err != nil {
		return wire.ForgeDone{}, err
	}
	out, err := gh.ReviewPR(ctx, r.Repo, r.Number, sha, true, "")
	if err != nil {
		return wire.ForgeDone{}, err
	}
	url, _ := out["url"].(string)
	return wire.ForgeDone{URL: optional(url)}, nil
}

// Rerun reruns the failed jobs of the failing checks' Actions runs.
func (g githubForge) Rerun(ctx context.Context, r forgeRef) (wire.ForgeDone, error) {
	if !r.pr() {
		return wire.ForgeDone{}, cannot(actionRerun)
	}
	gh, err := g.d.forgeGitHub()
	if err != nil {
		return wire.ForgeDone{}, err
	}
	runs, err := g.failedRuns(ctx, gh, r, "")
	if err != nil {
		return wire.ForgeDone{}, err
	}
	if len(runs) == 0 {
		return wire.ForgeDone{}, Invalid("forge/rerun: %s has no failed Actions run to rerun", r.Node.Ref)
	}
	var url string
	for _, run := range runs {
		out, err := gh.RerunFailed(ctx, r.Repo, run)
		if err != nil {
			return wire.ForgeDone{}, err
		}
		url, _ = out["url"].(string)
	}
	return wire.ForgeDone{URL: optional(url), Reran: new(int64(len(runs)))}, nil
}

// AddChild makes a new issue in the epic's repo and makes it a sub-issue, or makes the issue
// that child.Issue names (#12, owner/repo#12 or its URL) one.
func (g githubForge) AddChild(ctx context.Context, epic forgeRef, child forgeChild) (wire.ForgeDone, error) {
	const method = "forge/add-child"
	gh, err := g.d.forgeGitHub()
	if err != nil {
		return wire.ForgeDone{}, err
	}
	if child.Issue == "" {
		n, url, err := gh.CreateIssue(ctx, epic.Repo, child.Title, child.Labels)
		if err == nil {
			err = gh.AddSubIssue(ctx, epic.Repo, epic.Number, epic.Repo, n)
		}
		return wire.ForgeDone{URL: optional(url)}, err
	}
	m := githubIssueRef.FindStringSubmatch(child.Issue)
	if m == nil {
		return wire.ForgeDone{}, Invalid("%s: %q is not a GitHub issue: give #12, owner/repo#12 or its URL", method, child.Issue)
	}
	repo := strings.ToLower(m[1] + m[2])
	if repo == "" {
		repo = epic.Repo
	}
	n, _ := strconv.Atoi(m[3])
	if (forgeRepo{"github", repo}).issue(n) == epic.Node {
		return wire.ForgeDone{}, Invalid("%s: an epic is not its own child", method)
	}
	return wire.ForgeDone{}, gh.AddSubIssue(ctx, epic.Repo, epic.Number, repo, n)
}

func (g githubForge) SetBlockedBy(ctx context.Context, r, blocker forgeRef, blocked bool) error {
	gh, err := g.d.forgeGitHub()
	if err != nil {
		return err
	}
	return gh.SetBlockedBy(ctx, r.Repo, r.Number, blocker.Repo, blocker.Number, blocked)
}

// githubStart is the new-agent form for a GitHub issue (Start Agent), as the GitHub issues view
// fills it (#834): the prompt names the issue and how to read it, and the session is labelled with it.
func githubStart(i wire.ForgeItem) *wire.ForgeStart {
	repo, n, ok := nodeOfRepo(i.Node)
	if !ok {
		return nil
	}
	on := " --repo " + repo.path
	return numberedStart(fmt.Sprintf("#%d: %s\n\nWork on this GitHub issue (`gh issue view %d%s`).\n\n"+
		"First assign it to yourself: `gh issue edit %d%s --add-assignee @me`.", n, i.Title, n, on, n, on), n, i.Title)
}
