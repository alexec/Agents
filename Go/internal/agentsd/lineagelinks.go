package agentsd

import (
	"encoding/json"
	"log"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// The links the host makes on its own (#2349), so agents and people seldom have to:
//
//   - A session's label #n, P#n or a Linear key (ENG-4) is a works-on link to that issue or
//     PR: from the start (the Issues and PR pages give one), or added later by the agent
//     (set_session_labels) or the person. Taking the label off ends the link.
//   - A helper is started by its parent session, a workflow's session by its run, and the
//     run is part of its workflow.
//   - pr.opened links the PR to every session that worked on its branch (opens), and the
//     PR to the issues its body closes (fixes). pr.merged and pr.closed link what its body
//     closes too, so a closed PR's cost stays against its issues (#2350).
//   - Each forge issue named here is part of its milestone (lineagemilestone.go, #2935).
//   - pr.merged and pr.closed end the sessions' links to the PR; pr.closed also ends its
//     fixes links, as a PR closed without a merge fixed nothing. An archived session's
//     links end.
//
// The work is done in order on one goroutine, off the agent lock: a label's issue needs
// the folder's git remote.

// lineageJobsHeld bounds the work waiting; past it, a link is dropped and logged.
const lineageJobsHeld = 1024

type lineageLinker struct {
	linkerOnce sync.Once
	linkerJobs chan func()
	repoMu     sync.Mutex
	// repos is each folder's forge repo, looked up once: a remote seldom changes.
	repos map[string]forgeRepo
}

// forgeRepo is a repository on a forge, as lineage refs name it: forge github or gitlab,
// path owner/repo (group/sub/project on GitLab), lower case. The zero value is none.
type forgeRepo struct{ forge, path string }

func (r forgeRepo) issue(n int) wire.LineageNode {
	return wire.LineageNode{Kind: lineage.KindIssue, Ref: r.forge + ":" + r.path + "#" + strconv.Itoa(n)}
}

// pr is a pull request, or a merge request on GitLab, which numbers them apart from issues.
func (r forgeRepo) pr(n int) wire.LineageNode {
	mark := "#"
	if r.forge == "gitlab" {
		mark = "!"
	}
	return wire.LineageNode{Kind: lineage.KindPR, Ref: r.forge + ":" + r.path + mark + strconv.Itoa(n)}
}

// forgeOf is the forge a remote is on: github.com, or a host whose name says GitLab.
func forgeOf(host, path string) forgeRepo {
	path = strings.ToLower(strings.TrimSuffix(strings.Trim(path, "/"), ".git"))
	switch host = strings.ToLower(host); {
	case path == "":
		return forgeRepo{}
	case host == "github.com":
		return forgeRepo{"github", path}
	case strings.Contains(host, "gitlab"):
		return forgeRepo{"gitlab", path}
	}
	return forgeRepo{}
}

// prOfURL is the repo and number of a PR's web address: github.com/o/r/pull/5, or
// <gitlab>/group/project/-/merge_requests/5.
func prOfURL(raw string) (forgeRepo, int, bool) {
	u, err := url.Parse(raw)
	if err != nil {
		return forgeRepo{}, 0, false
	}
	path := strings.Trim(u.Path, "/")
	for _, sep := range []string{"/-/merge_requests/", "/pull/"} {
		if repo, num, ok := strings.Cut(path, sep); ok {
			n, err := strconv.Atoi(strings.SplitN(num, "/", 2)[0])
			r := forgeOf(u.Host, repo)
			if err != nil || n <= 0 || r.forge == "" || (sep == "/pull/") != (r.forge == "github") {
				return forgeRepo{}, 0, false
			}
			return r, n, true
		}
	}
	return forgeRepo{}, 0, false
}

func sessionNode(id wire.UUID) wire.LineageNode {
	return wire.LineageNode{Kind: lineage.KindSession, Ref: "session:" + string(id)}
}

var (
	issueLabel  = regexp.MustCompile(`^#([0-9]{1,9})$`)
	prLabel     = regexp.MustCompile(`^P#([0-9]{1,9})$`)
	linearLabel = regexp.MustCompile(`^[A-Z][A-Z0-9]{0,9}-[0-9]{1,9}$`)
	// linearTeam is a Linear team's key, as ENG.
	linearTeam = regexp.MustCompile(`^[A-Z][A-Z0-9]{0,9}$`)
)

// labelNode is the issue or PR a label names, in the folder's repo: #n, P#n, or a Linear
// key such as ENG-4.
func (d *Daemon) labelNode(folder, label string) (wire.LineageNode, bool) {
	if linearLabel.MatchString(label) {
		return wire.LineageNode{Kind: lineage.KindIssue, Ref: "linear:" + label}, true
	}
	issue, pr := issueLabel.FindStringSubmatch(label), prLabel.FindStringSubmatch(label)
	if issue == nil && pr == nil {
		return wire.LineageNode{}, false
	}
	repo := d.folderRepo(folder)
	if repo.forge == "" {
		return wire.LineageNode{}, false
	}
	if issue != nil {
		n, _ := strconv.Atoi(issue[1])
		return repo.issue(n), n > 0
	}
	n, _ := strconv.Atoi(pr[1])
	return repo.pr(n), n > 0
}

// folderRepo is the forge repo a folder pushes to, from its origin remote.
func (d *Daemon) folderRepo(folder string) forgeRepo {
	d.repoMu.Lock()
	r, ok := d.repos[folder]
	d.repoMu.Unlock()
	if ok {
		return r
	}
	if out, err := git(folder, "remote", "get-url", "origin"); err == nil {
		if remote, ok := parseRemote(out); ok {
			r = forgeOf(remote.host, remote.path)
		}
	} else if !isDir(folder) {
		// A folder gone is not remembered, in case it comes back.
		return forgeRepo{}
	}
	d.repoMu.Lock()
	if d.repos == nil {
		d.repos = map[string]forgeRepo{}
	}
	d.repos[folder] = r
	d.repoMu.Unlock()
	return r
}

// lineageDo runs f after the work before it, on the linker's goroutine.
func (d *Daemon) lineageDo(f func()) {
	d.linkerOnce.Do(func() {
		d.linkerJobs = make(chan func(), lineageJobsHeld)
		jobs := d.linkerJobs
		safe.Go("lineage links", func() {
			for job := range jobs {
				job()
			}
		})
	})
	select {
	case d.linkerJobs <- f:
	default:
		log.Printf("lineage: %d links wait to be written; one was dropped", lineageJobsHeld)
	}
}

// lineageSettle waits, at most wait, for the work given so far.
func (d *Daemon) lineageSettle(wait time.Duration) {
	done := make(chan struct{})
	d.lineageDo(func() { close(done) })
	select {
	case <-done:
	case <-time.After(wait):
	}
}

func (d *Daemon) link(from, to wire.LineageNode, rel, source string) {
	d.linkAt(from, to, rel, source, nowFunc())
}

// linkAt is link, at a time other than now: a release's links are backfilled to the tag's
// commit time (#3023), so a tag found hours or days late still lands where it happened.
func (d *Daemon) linkAt(from, to wire.LineageNode, rel, source string, at time.Time) {
	if _, err := d.lineage().Link(wire.LineageLinkRequest{From: from, To: to, Rel: rel, Source: source}, at); err != nil {
		log.Printf("lineage: %s %s %s: %v", from.Ref, rel, to.Ref, err)
	}
}

func (d *Daemon) unlink(from, to wire.LineageNode, rel string) {
	if _, err := d.lineage().End(wire.LineageEndRequest{From: from, To: to, Rel: rel}, nowFunc()); err != nil {
		log.Printf("lineage: end %s %s %s: %v", from.Ref, rel, to.Ref, err)
	}
}

// endLinks ends a node's active links that keep, either way.
func (d *Daemon) endLinks(n wire.LineageNode, keep func(wire.LineageLink) bool) {
	for _, l := range d.lineage().Links(n).Links {
		if l.EndedAt == nil && keep(l) {
			d.unlink(l.From, l.To, l.Rel)
		}
	}
}

// noteLineage makes the links a session's change says: before is nil for a new record.
func (d *Daemon) noteLineage(before *wire.Agent, a wire.Agent) {
	if a.Purpose != nil {
		return
	}
	var was wire.Agent
	if before != nil {
		was = *before
	}
	had := map[string]bool{}
	for _, l := range was.Labels {
		had[l.Value] = true
	}
	has := map[string]bool{}
	var added []wire.SessionLabel
	for _, l := range a.Labels {
		has[l.Value] = true
		if !had[l.Value] {
			added = append(added, l)
		}
	}
	var removed []string
	for _, l := range was.Labels {
		if !has[l.Value] {
			removed = append(removed, l.Value)
		}
	}
	newly := func(now, then *wire.UUID) *wire.UUID {
		if now != nil && (then == nil || *then != *now) {
			return now
		}
		return nil
	}
	helper := newly(a.StartedByAgent, was.StartedByAgent)
	run := newly(a.StartedByRun, was.StartedByRun)
	var workflow *string
	if a.StartedByWorkflow != nil && (was.StartedByWorkflow == nil || *was.StartedByWorkflow != *a.StartedByWorkflow) {
		workflow = a.StartedByWorkflow
	}
	archived := before != nil && was.State != wire.AgentStateArchived && a.State == wire.AgentStateArchived
	if len(added) == 0 && len(removed) == 0 && helper == nil && run == nil && workflow == nil && !archived {
		return
	}
	s, folder := sessionNode(a.ID), folderPath(&a)
	d.lineageDo(func() {
		if helper != nil {
			d.link(sessionNode(*helper), s, lineage.RelStarted, lineage.SourceHelper)
		}
		if workflow != nil || run != nil {
			var wf wire.LineageNode
			if workflow != nil {
				wf = wire.LineageNode{Kind: lineage.KindWorkflow, Ref: "workflow:" + folder + "/" + *workflow}
			}
			switch {
			case run != nil:
				r := wire.LineageNode{Kind: lineage.KindWorkflowRun, Ref: "run:" + string(*run)}
				d.link(r, s, lineage.RelStarted, lineage.SourceHelper)
				if workflow != nil {
					d.link(r, wf, lineage.RelPartOf, lineage.SourceHelper)
				}
			default:
				d.link(wf, s, lineage.RelStarted, lineage.SourceHelper)
			}
		}
		for _, l := range added {
			to, ok := d.labelNode(folder, l.Value)
			if !ok {
				continue
			}
			source := lineage.SourceStart
			if before != nil {
				source = lineage.SourcePerson
				if l.Owner == wire.SessionLabelOwnerAgent {
					source = lineage.SourceAgent
				}
			}
			d.link(s, to, lineage.RelWorksOn, source)
			if repo, n, ok := issueOfNode(to); ok {
				d.noteIssueMilestone(folder, repo, n)
			}
		}
		for _, v := range removed {
			if to, ok := d.labelNode(folder, v); ok {
				d.unlink(s, to, lineage.RelWorksOn)
			}
		}
		if archived {
			d.endLinks(s, func(l wire.LineageLink) bool { return l.From == s })
		}
	})
}

// prEventPayload is what a pr.* event of the GitHub and GitLab servers says of its PR.
type prEventPayload struct {
	PR struct {
		Title  string   `json:"title"`
		Branch string   `json:"branch"`
		URL    string   `json:"url"`
		Fixes  []string `json:"fixes"`
	} `json:"pr"`
}

// lineageEvent makes the links a raised event says: pr.opened, pr.merged and pr.closed.
func (d *Daemon) lineageEvent(e wire.Event) {
	switch e.Name {
	case "pr.opened", "pr.merged", "pr.closed", "checks.failed":
	default:
		return
	}
	var p prEventPayload
	if json.Unmarshal([]byte(e.Details["payload"]), &p) != nil {
		return
	}
	repo, n, ok := prOfURL(p.PR.URL)
	if !ok {
		return
	}
	pr := repo.pr(n)
	if e.Name == "checks.failed" {
		d.lineageDo(func() { d.notePROutcome(pr, e.Name, p.PR.Title) })
		return
	}
	var sessions []wire.UUID
	if e.Name == "pr.opened" && p.PR.Branch != "" {
		for _, a := range d.Store.Agents() {
			if a.Worktree != nil && a.Worktree.Branch != nil && *a.Worktree.Branch == p.PR.Branch && a.Purpose == nil {
				sessions = append(sessions, a.ID)
			}
		}
	}
	d.lineageDo(func() {
		for _, id := range sessions {
			// The same branch name in another repo is another branch.
			if a := d.Store.Agent(id); a != nil && d.folderRepo(folderPath(a)) == repo {
				d.link(sessionNode(id), pr, lineage.RelOpens, lineage.SourceBranch)
			}
		}
		// A PR closed without a merge links its issues too, and the links end below: it fixed
		// nothing, but its cost stays against them, as waste (#2350).
		folder := ""
		if len(p.PR.Fixes) > 0 {
			folder = d.repoFolder(repo)
		}
		for _, f := range p.PR.Fixes {
			if issue, ok := fixedIssue(repo, f); ok {
				d.link(pr, issue, lineage.RelFixes, lineage.SourcePRBody)
				if r, n, ok := issueOfNode(issue); ok {
					d.noteIssueMilestone(folder, r, n)
				}
			}
		}
		// How it ended, for its cost (#2350).
		d.notePROutcome(pr, e.Name, p.PR.Title)
		if e.Name == "pr.merged" {
			// Its cost, on the PR (#2352).
			d.prMerged(repo, n, pr)
		}
		if e.Name == "pr.opened" {
			return
		}
		closed := e.Name == "pr.closed"
		d.endLinks(pr, func(l wire.LineageLink) bool {
			return l.To == pr && l.From.Kind == lineage.KindSession || closed && l.From == pr && l.Rel == lineage.RelFixes
		})
	})
}

// fixedIssue is the issue a PR's fixes names: "#12" in the PR's own repo, or
// "owner/repo#12" on the same forge.
func fixedIssue(repo forgeRepo, ref string) (wire.LineageNode, bool) {
	path, num, ok := strings.Cut(ref, "#")
	n, err := strconv.Atoi(num)
	if !ok || err != nil || n <= 0 {
		return wire.LineageNode{}, false
	}
	if path != "" {
		repo = forgeRepo{repo.forge, strings.ToLower(path)}
	}
	return repo.issue(n), true
}
