package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Each issue is part of its parent (#3582), so a walk from an epic reaches its children:
//
//   - For each GitHub issue the host knows (a session's #n, a PR's fixes), it asks GitHub for
//     the issue's parent (a sub-issue's epic) and its sub-issues, with the person's own gh in
//     the folder. The issue is part-of its parent, source forge, and each of its sub-issues (at
//     most subIssuesMax) is part-of it. GitLab's, Forgejo's and Bitbucket's APIs say no parent,
//     so lineage does not ask them.
//   - The answer is kept parentRecheck: an issue named again after that is asked again. When
//     its parent is another one now, the old link ends and a new one starts; with none, the
//     link ends.
//   - Bounded: one lookup at a time, on its own goroutine so the linker never waits on the
//     forge; at most parentLookupsHeld wait, each issue once, and parentsCached answers are
//     kept.
//
// #3878 removed the milestone an issue is part of (#2935): Work has no milestones now.
//
// Decided: the host asks the forge, and the GitHub server adds nothing to the pr.* events,
// because a session's #n label comes with no event, and the host asks gh already for the cost
// comment (#2352).

const (
	parentRecheck     = time.Hour
	parentLookupsHeld = 256
	parentsCached     = 2_000
	// subIssuesMax bounds the sub-issues of one parent that are linked: one page of the forge's.
	subIssuesMax = 100
)

// issueOnForge is what the forge says of an issue: the issue it is a sub-issue of, the zero
// node for none; and its own sub-issues.
type issueOnForge struct {
	parent   wire.LineageNode
	children []wire.LineageNode
}

// parentLookup asks the forge for an issue's parent and sub-issues. Tests set it, or a
// daemon's issueLookup.
var parentLookup = forgeIssue

type issueLookup func(ctx context.Context, folder string, repo forgeRepo, n int) (issueOnForge, error)

type issueParentBook struct {
	issueMu      sync.Mutex
	issueOnce    sync.Once
	issueJobs    chan parentJob
	issueWaiting map[wire.LineageNode]bool
	// issueAsked is when each issue was asked; a failed lookup waits as long, leaving its links.
	issueAsked map[wire.LineageNode]time.Time
	// issueLookup, when set, is asked in place of parentLookup.
	issueLookup issueLookup
	// subIssues is each parent's sub-issues in the forge's order, as it last said them: the
	// epic's order a search for it groups its sessions in (#3900). Kept as long as issueAsked.
	subIssues map[wire.LineageNode][]wire.LineageNode
}

type parentJob struct {
	folder string
	repo   forgeRepo
	n      int
}

// noteIssueParent asks, unless it asked within parentRecheck, for a GitHub issue's parent
// and sub-issues, and links them.
func (d *Daemon) noteIssueParent(folder string, repo forgeRepo, n int) {
	if repo.forge != "github" || n <= 0 {
		return
	}
	issue := repo.issue(n)
	d.issueMu.Lock()
	defer d.issueMu.Unlock()
	if at, ok := d.issueAsked[issue]; ok && nowFunc().Sub(at) < parentRecheck || d.issueWaiting[issue] {
		return
	}
	d.issueOnce.Do(func() {
		d.issueJobs = make(chan parentJob, parentLookupsHeld)
		jobs := d.issueJobs
		safe.Go("lineage parents", func() {
			for j := range jobs {
				d.askIssueParent(j)
			}
		})
	})
	select {
	case d.issueJobs <- parentJob{folder, repo, n}:
		if d.issueWaiting == nil {
			d.issueWaiting = map[wire.LineageNode]bool{}
		}
		d.issueWaiting[issue] = true
	default:
		log.Printf("lineage: %d parent lookups wait; %s was not asked", parentLookupsHeld, issue.Ref)
	}
}

func (d *Daemon) askIssueParent(j parentJob) {
	issue := j.repo.issue(j.n)
	ask := parentLookup
	if d.issueLookup != nil {
		ask = d.issueLookup
	}
	got, err := ask(context.Background(), j.folder, j.repo, j.n)
	if err != nil {
		log.Printf("lineage: the parent of %s: %v", issue.Ref, err)
	} else {
		d.lineageDo(func() {
			d.endLinks(issue, func(l wire.LineageLink) bool {
				return l.From == issue && l.Rel == lineage.RelPartOf && l.To.Kind == lineage.KindIssue &&
					l.Source == lineage.SourceForge && l.To != got.parent
			})
			if got.parent != (wire.LineageNode{}) {
				d.link(issue, got.parent, lineage.RelPartOf, lineage.SourceForge)
			}
			for _, child := range got.children {
				d.link(child, issue, lineage.RelPartOf, lineage.SourceForge)
			}
		})
	}
// After the links are given: no longer waiting means they are in the linker's work.
	d.issueMu.Lock()
	defer d.issueMu.Unlock()
	delete(d.issueWaiting, issue)
	if err == nil {
		if d.subIssues == nil {
			d.subIssues = map[wire.LineageNode][]wire.LineageNode{}
		}
		if len(got.children) > 0 {
			d.subIssues[issue] = got.children
		} else {
			delete(d.subIssues, issue)
		}
	}
	if d.issueAsked == nil {
		d.issueAsked = map[wire.LineageNode]time.Time{}
	}
	if len(d.issueAsked) >= parentsCached {
		d.dropOldestAnswerLocked()
	}
	d.issueAsked[issue] = nowFunc()
}

// dropOldestAnswerLocked makes room for one more answer.
func (d *Daemon) dropOldestAnswerLocked() {
	var oldest wire.LineageNode
	var at time.Time
	for n, asked := range d.issueAsked {
		if at.IsZero() || asked.Before(at) {
			oldest, at = n, asked
		}
	}
	delete(d.issueAsked, oldest)
	delete(d.subIssues, oldest)
}

// subIssueOrder is the parent's sub-issues in the forge's order, as it last said them (#3900).
func (d *Daemon) subIssueOrder(parent wire.LineageNode) []wire.LineageNode {
	d.issueMu.Lock()
	defer d.issueMu.Unlock()
	return d.subIssues[parent]
}

// repoFolder is a folder of repo, where gh or glab finds its sign-in; "" for none.
func (d *Daemon) repoFolder(repo forgeRepo) string {
	for _, f := range d.folderPaths() {
		if d.folderRepo(f) == repo {
			return f
		}
	}
	return ""
}

// forgeIssue asks gh, in folder, for a GitHub issue's parent, and, when it has sub-issues,
// for them.
func forgeIssue(ctx context.Context, folder string, repo forgeRepo, n int) (issueOnForge, error) {
	if repo.forge != "github" {
		return issueOnForge{}, fmt.Errorf("no parents on %s", repo.forge)
	}
	exe := forgeCLI("gh")
	if exe == "" {
		return issueOnForge{}, errors.New("gh is not installed")
	}
	out, err := runForgeCLI(ctx, exe, folder, nil, "api", fmt.Sprintf("repos/%s/issues/%d", repo.path, n))
	if err != nil {
		return issueOnForge{}, err
	}
	got, subIssues, err := issueOnForgeOf(out)
	if err != nil || subIssues == 0 {
		return got, err
	}
	out, err = runForgeCLI(ctx, exe, folder, nil, "api", fmt.Sprintf("repos/%s/issues/%d/sub_issues?per_page=%d", repo.path, n, subIssuesMax))
	if err != nil {
		// The parent stands; the sub-issues are asked the next time.
		log.Printf("lineage: the sub-issues of %s: %v", repo.issue(n).Ref, err)
		return got, nil
	}
	got.children, err = subIssuesOf(out)
	return got, err
}

// issueOnForgeOf is an issue as GitHub's API says it: its parent, and how many sub-issues it
// has.
func issueOnForgeOf(out []byte) (issueOnForge, int, error) {
	var issue struct {
		ParentIssueURL string `json:"parent_issue_url"`
		SubIssues      struct {
			Total int `json:"total"`
		} `json:"sub_issues_summary"`
	}
	if err := json.Unmarshal(out, &issue); err != nil {
		return issueOnForge{}, 0, fmt.Errorf("the forge did not say the issue: %v", err)
	}
	got := issueOnForge{}
	if repo, n, ok := issueOfAPIURL(issue.ParentIssueURL); ok {
		got.parent = repo.issue(n)
	}
	return got, issue.SubIssues.Total, nil
}

// subIssuesOf is the issues a GitHub sub_issues list names, at most subIssuesMax.
func subIssuesOf(out []byte) ([]wire.LineageNode, error) {
	var list []struct {
		HTMLURL string `json:"html_url"`
	}
	if err := json.Unmarshal(out, &list); err != nil {
		return nil, fmt.Errorf("the forge did not say the sub-issues: %v", err)
	}
	var children []wire.LineageNode
	for _, c := range list {
		if repo, n, ok := issueOfURL(c.HTMLURL); ok && len(children) < subIssuesMax {
			children = append(children, repo.issue(n))
		}
	}
	return children, nil
}

// issueOfAPIURL is the repo and number of a GitHub API issue address:
// https://api.github.com/repos/o/r/issues/12.
func issueOfAPIURL(raw string) (forgeRepo, int, bool) {
	u, err := url.Parse(raw)
	if err != nil || !strings.EqualFold(u.Host, "api.github.com") {
		return forgeRepo{}, 0, false
	}
	rest, ok := strings.CutPrefix(u.Path, "/repos/")
	if !ok {
		return forgeRepo{}, 0, false
	}
	return issueOfURL("https://github.com/" + rest)
}

// issueOfURL is the repo and number of an issue's web address: github.com/o/r/issues/5,
// <gitlab>/group/project/-/issues/5, or codeberg.org/o/r/issues/5.
func issueOfURL(raw string) (forgeRepo, int, bool) {
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") {
		return forgeRepo{}, 0, false
	}
	return ofURL(u.Host, strings.Trim(u.Path, "/"), false)
}

// issueOfURLOn is issueOfURL, or an issue on the Forgejo whose root is root (the connected
// one's, "" for none): its host's name need not say Forgejo, as issueOfURL's must.
func issueOfURLOn(raw, root string) (forgeRepo, int, bool) {
	if repo, n, ok := issueOfURL(raw); ok || root == "" {
		return repo, n, ok
	}
	return forgejoOfURLOn(raw, root, "/issues/")
}

// forgejoOfURLOn is the repo and number at raw on the Forgejo whose root is root, under its
// owner/repo, then sep (/issues/ or /pulls/), then the number.
func forgejoOfURLOn(raw, root, sep string) (forgeRepo, int, bool) {
	u, err := url.Parse(raw)
	r, rerr := url.Parse(root)
	if err != nil || rerr != nil || root == "" || !strings.EqualFold(u.Scheme, r.Scheme) || !strings.EqualFold(u.Host, r.Host) {
		return forgeRepo{}, 0, false
	}
	rest, ok := strings.CutPrefix(u.Path, r.Path)
	repo, num, cut := strings.Cut(strings.Trim(rest, "/"), sep)
	n, nerr := strconv.Atoi(strings.SplitN(num, "/", 2)[0])
	if !ok || !cut || nerr != nil || n <= 0 || strings.Count(repo, "/") != 1 || strings.HasPrefix(repo, "/") || strings.HasSuffix(repo, "/") {
		return forgeRepo{}, 0, false
	}
	return forgeRepo{"forgejo", repoPath(repo)}, n, true
}

// issueOfNode is the repo and number of a forge issue node: github:o/r#12, forgejo:o/r#12,
// bitbucket:w/r#12.
func issueOfNode(n wire.LineageNode) (forgeRepo, int, bool) {
	forge, rest, ok := strings.Cut(n.Ref, ":")
	if _, known := kindOf(forge); n.Kind != lineage.KindIssue || !ok || !known {
		return forgeRepo{}, 0, false
	}
	path, num, ok := strings.Cut(rest, "#")
	i, err := strconv.Atoi(num)
	if !ok || err != nil || i <= 0 || path == "" {
		return forgeRepo{}, 0, false
	}
	return forgeRepo{forge, path}, i, true
}
