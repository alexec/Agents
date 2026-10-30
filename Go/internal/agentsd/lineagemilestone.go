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
//     for the issue's milestone, with the person's own gh or glab in the folder, and links
//     the issue part-of the milestone, source forge. A milestone is
//     github:<owner>/<repo>/milestone/<number>, or gitlab:<group>/<project>/milestone/<iid>.
//   - The answer is kept milestoneRecheck: an issue named again after that is asked again.
//     When its milestone is another one now, the old link ends and a new one starts; with
//     none, the link ends.
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
)

// milestoneLookup asks the forge for an issue's milestone: its number (GitLab: its iid),
// or 0 for none. Tests set it, or a daemon's issueLookup.
var milestoneLookup = forgeIssueMilestone

type issueLookup func(ctx context.Context, folder string, repo forgeRepo, n int) (int, error)

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
// milestone, and links the issue to it.
func (d *Daemon) noteIssueMilestone(folder string, repo forgeRepo, n int) {
	if repo.forge == "" || n <= 0 {
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
	if d.issueLookup != nil {
		ask = d.issueLookup
	}
	m, err := ask(context.Background(), j.folder, j.repo, j.n)
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
		})
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

// forgeIssueMilestone asks gh or glab, in folder, for an issue's milestone.
func forgeIssueMilestone(ctx context.Context, folder string, repo forgeRepo, n int) (int, error) {
	var exe, path string
	switch repo.forge {
	case "github":
		exe, path = forgeCLI("gh"), fmt.Sprintf("repos/%s/issues/%d", repo.path, n)
	case "gitlab":
		exe, path = forgeCLI("glab"), fmt.Sprintf("projects/%s/issues/%d", url.PathEscape(repo.path), n)
	default:
		return 0, fmt.Errorf("no issues on %s", repo.forge)
	}
	if exe == "" {
		return 0, errors.New("gh or glab is not installed")
	}
	out, err := runForgeCLI(ctx, exe, folder, nil, "api", path)
	if err != nil {
		return 0, err
	}
	return issueMilestoneOf(out)
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

// issueOfNode is the repo and number of a forge issue node: github:o/r#12.
func issueOfNode(n wire.LineageNode) (forgeRepo, int, bool) {
	forge, rest, ok := strings.Cut(n.Ref, ":")
	if n.Kind != lineage.KindIssue || !ok || (forge != "github" && forge != "gitlab") {
		return forgeRepo{}, 0, false
	}
	path, num, ok := strings.Cut(rest, "#")
	i, err := strconv.Atoi(num)
	if !ok || err != nil || i <= 0 || path == "" {
		return forgeRepo{}, 0, false
	}
	return forgeRepo{forge, path}, i, true
}
