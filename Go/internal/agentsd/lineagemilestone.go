package agentsd

import (
	"bytes"
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

// Each issue is part of its milestone (#2935), so a milestone's cost adds up (#2350):
//
//   - For each forge issue the host knows (a session's #n, a PR's fixes), it asks the forge
//     for the issue's milestone, with the person's own gh or glab in the folder (Forgejo: its
//     connection, lineageforgejo.go), and links the issue part-of the milestone, source forge.
//     A milestone is github:<owner>/<repo>/milestone/<number>,
//     gitlab:<group>/<project>/milestone/<iid>, or forgejo:<owner>/<repo>/milestone/<id>.
//   - The answer is kept milestoneRecheck: an issue named again after that is asked again.
//     When its milestone is another one now, the old link ends and a new one starts; with
//     none, the link ends.
//   - The same answer says the issue's parent (a GitHub sub-issue's epic, #3582): the issue
//     is part-of its parent, source forge, and a parent's sub-issues (at most
//     subIssuesMax) are each part-of it, so a walk from an epic reaches its children. A
//     move or a removal ends the old link as for a milestone. GitLab's and Forgejo's REST
//     APIs say no parent, so their issues get none.
//   - Bounded: one lookup at a time, on its own goroutine so the linker never waits on the
//     forge; at most milestoneLookupsHeld wait, each issue once, and milestonesCached
//     answers are kept.
//
// Decided: the host asks the forge, and the GitHub and GitLab servers add nothing to the
// pr.* events, because a session's #n label comes with no event, and the host asks gh and
// glab already for the cost comment (#2352).

const (
	milestoneRecheck     = time.Hour
	milestoneLookupsHeld = 256
	milestonesCached     = 2_000
	// subIssuesMax bounds the sub-issues of one parent that are linked: one page of the forge's.
	subIssuesMax = 100
)

// issueOnForge is what the forge says of an issue: its milestone's number (GitLab: its
// iid), 0 for none; the issue it is a sub-issue of, the zero node for none; and its own
// sub-issues.
type issueOnForge struct {
	milestone int
	parent    wire.LineageNode
	children  []wire.LineageNode
}

// milestoneLookup asks the forge for an issue's milestone, parent and sub-issues. Tests set
// it, or a daemon's issueLookup.
var milestoneLookup = forgeIssue

type issueLookup func(ctx context.Context, folder string, repo forgeRepo, n int) (issueOnForge, error)

type issueMilestoneBook struct {
	issueMu      sync.Mutex
	issueOnce    sync.Once
	issueJobs    chan milestoneJob
	issueWaiting map[wire.LineageNode]bool
	// issueAsked is when each issue was asked; a failed lookup waits as long, leaving its links.
	issueAsked map[wire.LineageNode]time.Time
	// issueLookup, when set, is asked in place of milestoneLookup.
	issueLookup issueLookup
}

type milestoneJob struct {
	folder string
	repo   forgeRepo
	n      int
}

func (r forgeRepo) milestone(n int) wire.LineageNode {
	return wire.LineageNode{Kind: lineage.KindMilestone, Ref: r.forge + ":" + r.path + "/milestone/" + strconv.Itoa(n)}
}

// noteIssueMilestone asks, unless it asked within milestoneRecheck, for an issue's
// milestone, and links the issue to it: on a forge lineage asks (forgeKind.cli).
func (d *Daemon) noteIssueMilestone(folder string, repo forgeRepo, n int) {
	if !repo.asks() || n <= 0 {
		return
	}
	issue := repo.issue(n)
	d.issueMu.Lock()
	defer d.issueMu.Unlock()
	if at, ok := d.issueAsked[issue]; ok && nowFunc().Sub(at) < milestoneRecheck || d.issueWaiting[issue] {
		return
	}
	d.issueOnce.Do(func() {
		d.issueJobs = make(chan milestoneJob, milestoneLookupsHeld)
		jobs := d.issueJobs
		safe.Go("lineage milestones", func() {
			for j := range jobs {
				d.askIssueMilestone(j)
			}
		})
	})
	select {
	case d.issueJobs <- milestoneJob{folder, repo, n}:
		if d.issueWaiting == nil {
			d.issueWaiting = map[wire.LineageNode]bool{}
		}
		d.issueWaiting[issue] = true
	default:
		log.Printf("lineage: %d milestone lookups wait; %s was not asked", milestoneLookupsHeld, issue.Ref)
	}
}

func (d *Daemon) askIssueMilestone(j milestoneJob) {
	issue := j.repo.issue(j.n)
	ask := milestoneLookup
	if j.repo.forge == "forgejo" {
		ask = d.forgejoIssue
	}
	if d.issueLookup != nil {
		ask = d.issueLookup
	}
	got, err := ask(context.Background(), j.folder, j.repo, j.n)
	m := got.milestone
	if err != nil {
		log.Printf("lineage: the milestone of %s: %v", issue.Ref, err)
	} else {
		d.lineageDo(func() {
			to := wire.LineageNode{}
			if m > 0 {
				to = j.repo.milestone(m)
			}
			d.endLinks(issue, func(l wire.LineageLink) bool {
				return l.From == issue && l.Rel == lineage.RelPartOf && l.To.Kind == lineage.KindMilestone &&
					l.Source == lineage.SourceForge && l.To != to
			})
			if m > 0 {
				d.link(issue, to, lineage.RelPartOf, lineage.SourceForge)
			}
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
		if m > 0 {
			// Its title, for Work's Milestones (reports/nodes), which no walk asks for.
			d.resolveSoon(j.repo.milestone(m))
		}
	}
	// After the links are given: no longer waiting means they are in the linker's work.
	d.issueMu.Lock()
	defer d.issueMu.Unlock()
	delete(d.issueWaiting, issue)
	if d.issueAsked == nil {
		d.issueAsked = map[wire.LineageNode]time.Time{}
	}
	if len(d.issueAsked) >= milestonesCached {
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

// forgeIssue asks gh or glab, in folder, for an issue's milestone and parent, and, when it
// has sub-issues, for them.
func forgeIssue(ctx context.Context, folder string, repo forgeRepo, n int) (issueOnForge, error) {
	var exe, path string
	switch repo.forge {
	case "github":
		exe, path = forgeCLI("gh"), fmt.Sprintf("repos/%s/issues/%d", repo.path, n)
	case "gitlab":
		exe, path = forgeCLI("glab"), fmt.Sprintf("projects/%s/issues/%d", url.PathEscape(repo.path), n)
	default:
		return issueOnForge{}, fmt.Errorf("no issues on %s", repo.forge)
	}
	if exe == "" {
		return issueOnForge{}, errors.New("gh or glab is not installed")
	}
	out, err := runForgeCLI(ctx, exe, folder, nil, "api", path)
	if err != nil {
		return issueOnForge{}, err
	}
	got, subIssues, err := issueOnForgeOf(out)
	if err != nil || subIssues == 0 || repo.forge != "github" {
		return got, err
	}
	out, err = runForgeCLI(ctx, exe, folder, nil, "api", fmt.Sprintf("repos/%s/issues/%d/sub_issues?per_page=%d", repo.path, n, subIssuesMax))
	if err != nil {
		// The milestone and parent stand; the sub-issues are asked the next time.
		log.Printf("lineage: the sub-issues of %s: %v", repo.issue(n).Ref, err)
		return got, nil
	}
	got.children, err = subIssuesOf(out)
	return got, err
}

// issueOnForgeOf is an issue as the forge's API says it: its milestone and parent, and how
// many sub-issues it has.
func issueOnForgeOf(out []byte) (issueOnForge, int, error) {
	m, err := issueMilestoneOf(out)
	if err != nil {
		return issueOnForge{}, 0, err
	}
	var issue struct {
		ParentIssueURL string `json:"parent_issue_url"`
		SubIssues      struct {
			Total int `json:"total"`
		} `json:"sub_issues_summary"`
	}
	if err := json.Unmarshal(out, &issue); err != nil {
		return issueOnForge{}, 0, fmt.Errorf("the forge did not say the issue: %v", err)
	}
	got := issueOnForge{milestone: m}
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

// issueMilestoneOf is the milestone of an issue as the forge's API says it: number on
// GitHub, iid on GitLab, 0 for none.
func issueMilestoneOf(out []byte) (int, error) {
	var issue struct {
		Milestone *struct {
			Number int `json:"number"`
			IID    int `json:"iid"`
		} `json:"milestone"`
	}
	dec := json.NewDecoder(bytes.NewReader(out))
	if err := dec.Decode(&issue); err != nil {
		return 0, fmt.Errorf("the forge did not say the issue: %v", err)
	}
	switch m := issue.Milestone; {
	case m == nil:
		return 0, nil
	case m.Number > 0:
		return m.Number, nil
	case m.IID > 0:
		return m.IID, nil
	}
	return 0, errors.New("the forge did not say the milestone's number")
}

// issueOfNode is the repo and number of a forge issue node: github:o/r#12, forgejo:o/r#12.
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
