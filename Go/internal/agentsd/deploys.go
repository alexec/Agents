package agentsd

import (
	"context"
	"errors"
	"fmt"
	"log"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/connections"
	"github.com/agentloops-dev/agent-loops/Go/internal/githubmcp"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Waiting deploys (#3587): a GitHub Actions run held by an environment with required
// reviewers, as a release.yml job with environment: production, is a Needs You approval of
// the folder whose repo it runs in, while the person is one of its reviewers. Approve and
// Reject answer through GitHub's pending-deployments API with the person's own connection:
// the gate and its audit are GitHub's, and Agents adds no gate of its own. Only a window or a
// device answers an approval (Role.Allows), never an agent. Read on a poll of its own, as For
// Review's pull requests are (reviews.go), each GitHub repo once; the github server's
// deploy.waiting event is the same wait, for workflows and waits.

const (
	// deployCommitsShown bounds the commits a deploy's reading lists.
	deployCommitsShown = 200
	// deployApproved and deployRejected are the comments GitHub keeps with an answer.
	deployApproved = "Approved in Agent Loops"
	deployRejected = "Rejected in Agent Loops"
)

// deployEvery is the poll; deployFirst is how long after the start the first one is.
var (
	deployEvery = 2 * time.Minute
	deployFirst = 20 * time.Second
)

// waitingDeploy is a run waiting for the person, and the repo it runs in.
type waitingDeploy struct {
	repo string
	githubmcp.WaitingDeploy
}

// key is the approval's key: owner/name/<run id>.
func (w waitingDeploy) key() string { return w.repo + "/" + strconv.Itoa(w.Run.Run.ID) }

// digest is the wait the person was shown: its attempt and environments. An answer to an
// earlier one is refused.
func (w waitingDeploy) digest() string {
	ids := make([]string, len(w.Environments))
	for i, id := range w.EnvironmentIDs() {
		ids[i] = strconv.FormatInt(id, 10)
	}
	return strconv.Itoa(w.Run.Run.Attempt) + ":" + strings.Join(ids, ",")
}

func (w waitingDeploy) approval() wire.Approval {
	title := w.Run.Run.Name
	if title == "" {
		title = w.Run.Workflow
	}
	title += " to " + w.EnvironmentNames()
	line := "Waits for your approval"
	if w.Run.Run.Branch != "" {
		line = w.Run.Run.Branch + " waits for your approval"
	}
	digest := w.digest()
	a := wire.Approval{Kind: wire.ApprovalKindDeploy, Key: w.key(), Title: title, Digest: &digest, Line: line,
		Actions: []wire.ApprovalAction{wire.ApprovalActionApprove, wire.ApprovalActionDeny}}
	if at := forgeDate(w.Run.Run.UpdatedAt); at != 0 {
		a.Since = &at
	}
	return a
}

type deployBook struct {
	deployMu sync.Mutex
	// deploys is each folder's waiting deploys as last read, oldest first.
	deploys map[string][]waitingDeploy
}

// deployApprovals is a folder's waiting deploys as Needs You lists them.
func (d *Daemon) deployApprovals(folder string) []wire.Approval {
	d.deployMu.Lock()
	defer d.deployMu.Unlock()
	var out []wire.Approval
	for _, w := range d.deploys[folder] {
		out = append(out, w.approval())
	}
	return out
}

// waitingDeployOf is the folder's waiting deploy by its approval's key.
func (d *Daemon) waitingDeployOf(folder, key string) (waitingDeploy, bool) {
	d.deployMu.Lock()
	defer d.deployMu.Unlock()
	for _, w := range d.deploys[folder] {
		if w.key() == key {
			return w, true
		}
	}
	return waitingDeploy{}, false
}

// readDeploys reads every GitHub repo's waiting deploys once, and says each folder whose list
// changed. A repo that could not be read keeps its last list; with no connection, none waits.
func (d *Daemon) readDeploys(ctx context.Context) {
	gh, err := d.forgeGitHub()
	if err != nil {
		d.setDeploys(map[string][]waitingDeploy{}, nil)
		return
	}
	read := map[string][]waitingDeploy{}
	var kept []string
	for repo, folder := range (githubForge{d: d}).scopeOf(d.folderPaths()).folderOf {
		waiting, err := gh.WaitingDeploys(ctx, repo, "", "")
		if err != nil {
			log.Printf("deploys: the waiting runs of %s: %v", repo, err)
			kept = append(kept, folder)
			continue
		}
		for _, w := range waiting {
			if w.CanApprove {
				read[folder] = append(read[folder], waitingDeploy{repo: repo, WaitingDeploy: w})
			}
		}
	}
	d.setDeploys(read, kept)
}

// setDeploys keeps what was read, and the last list of each folder in kept, and says each
// folder that changed.
func (d *Daemon) setDeploys(read map[string][]waitingDeploy, kept []string) {
	d.deployMu.Lock()
	for _, folder := range kept {
		if old, ok := d.deploys[folder]; ok {
			read[folder] = old
		}
	}
	for folder := range read {
		slices.SortStableFunc(read[folder], func(a, b waitingDeploy) int {
			return strings.Compare(a.Run.Run.UpdatedAt, b.Run.Run.UpdatedAt)
		})
	}
	var changed []string
	for folder, ws := range read {
		if !slices.EqualFunc(ws, d.deploys[folder], sameWait) {
			changed = append(changed, folder)
		}
	}
	for folder := range d.deploys {
		if _, ok := read[folder]; !ok {
			changed = append(changed, folder)
		}
	}
	d.deploys = read
	d.deployMu.Unlock()
	for _, folder := range changed {
		_, _ = d.sendFolder(folder)
	}
}

func sameWait(a, b waitingDeploy) bool {
	return a.key() == b.key() && a.digest() == b.digest() && a.Run.Run.UpdatedAt == b.Run.Run.UpdatedAt
}

// dropDeploy takes an answered deploy out of its folder's list until the next read.
func (d *Daemon) dropDeploy(folder, key string) {
	d.deployMu.Lock()
	d.deploys[folder] = slices.DeleteFunc(d.deploys[folder], func(w waitingDeploy) bool { return w.key() == key })
	d.deployMu.Unlock()
}

// readDeploy is approvals/read for a waiting deploy: what ships. The run and the environments
// it waits on, then, for a version tag, the commits since the version tag before it, each
// one's title, read with the person's connection as the rest is.
func (d *Daemon) readDeploy(ctx context.Context, folder, key string) (wire.GuardedChangeReading, error) {
	w, ok := d.waitingDeployOf(folder, key)
	if !ok {
		return wire.GuardedChangeReading{}, Invalid("That deploy is not waiting any more.")
	}
	run := w.Run.Run
	digest := w.digest()
	same := func(text string) wire.GuardedDiffLine {
		return wire.GuardedDiffLine{Kind: wire.GuardedDiffLineKindSame, Text: text}
	}
	lines := []wire.GuardedDiffLine{
		same(fmt.Sprintf("Run: %s, attempt %d, %s", run.Name, run.Attempt, run.URL)),
		same("Waits for: " + w.EnvironmentNames()),
	}
	if len(w.Reviewers) > 0 {
		lines = append(lines, same("Reviewers: "+strings.Join(w.Reviewers, ", ")))
	}
	if run.HeadSHA != "" {
		lines = append(lines, same("Commit: "+run.HeadSHA))
	}
	if versionTagPattern.MatchString(run.Branch) {
		lines = append(lines, d.deployCommitLines(ctx, w.repo, run.Branch)...)
	}
	return wire.GuardedChangeReading{Path: strings.TrimSpace(w.repo + " " + run.Branch), Digest: &digest, Lines: lines}, nil
}

// deployCommitLines are the commits a tag ships since the version tag before it, each its
// title as an added line, at most deployCommitsShown.
func (d *Daemon) deployCommitLines(ctx context.Context, repo, tag string) []wire.GuardedDiffLine {
	note := func(text string) []wire.GuardedDiffLine {
		return []wire.GuardedDiffLine{{Kind: wire.GuardedDiffLineKindSame, Text: text}}
	}
	gh, err := d.forgeGitHub()
	if err != nil {
		return note("What ships could not be read: " + err.Error())
	}
	tags, err := gh.Tags(ctx, repo)
	if err != nil {
		return note("What ships could not be read: " + err.Error())
	}
	prev := ""
	for _, t := range tags {
		if versionTagPattern.MatchString(t) && versionLess(versionOf(t), versionOf(tag)) &&
			(prev == "" || versionLess(versionOf(prev), versionOf(t))) {
			prev = t
		}
	}
	if prev == "" {
		return note("No earlier version tag: this is the first release.")
	}
	commits, err := gh.Compare(ctx, repo, prev, tag)
	if err != nil {
		return note("What ships since " + prev + " could not be read: " + err.Error())
	}
	out := note(fmt.Sprintf("Ships since %s: %d commits", prev, len(commits)))
	for _, c := range commits[:min(len(commits), deployCommitsShown)] {
		title, _, _ := strings.Cut(c.Message, "\n")
		out = append(out, wire.GuardedDiffLine{Kind: wire.GuardedDiffLineKindAdded, Text: title})
	}
	if len(commits) > deployCommitsShown {
		out = append(out, note(fmt.Sprintf("And %d more.", len(commits)-deployCommitsShown))...)
	}
	return out
}

// answerDeploy is Approve or Reject of a waiting deploy, as the person, of the wait they were
// shown: GitHub refuses it when they are not one of its reviewers.
func (d *Daemon) answerDeploy(ctx context.Context, folder, key string, digest *string, approve bool) (wire.FolderSummary, error) {
	w, ok := d.waitingDeployOf(folder, key)
	if !ok {
		return wire.FolderSummary{}, Invalid("That deploy is not waiting any more.")
	}
	if digest == nil || *digest != w.digest() {
		return wire.FolderSummary{}, &Error{Code: wire.FailureNotChanged, Message: "That deploy waits on something else since you looked. Look again."}
	}
	gh, err := d.forgeGitHub()
	if err != nil {
		return wire.FolderSummary{}, err
	}
	comment := deployRejected
	if approve {
		comment = deployApproved
	}
	if err := gh.ReviewDeployments(ctx, w.repo, w.Run.Run.ID, w.EnvironmentIDs(), approve, comment); err != nil {
		log.Printf("deploys: %s of %s run %d (%s) failed: %v", comment, w.repo, w.Run.Run.ID, w.EnvironmentNames(), err)
		return wire.FolderSummary{}, deployRefusal(err)
	}
	log.Printf("deploys: %s of %s run %d (%s)", comment, w.repo, w.Run.Run.ID, w.EnvironmentNames())
	d.dropDeploy(folder, key)
	return d.sendFolder(folder)
}

// deployRefusal is a failed answer as the person reads it (#3932): GitHub's 403 is the App
// without the Deployments permission, since GitHub already said the person is a reviewer.
func deployRefusal(err error) error {
	var ge *githubmcp.GitHubError
	if errors.As(err, &ge) && ge.Kind == githubmcp.Failed && ge.Refused {
		return Invalid("GitHub refused this: the %s app needs the Deployments permission (read and write). "+
			"Your organisation or account owner sets it on the app and accepts it on the installation.", connections.GitHubAppSlug)
	}
	return err
}

// readDeploysEvery reads the waiting deploys until ctx ends, at Shutdown.
func (d *Daemon) readDeploysEvery(ctx context.Context) {
	t := time.NewTimer(deployFirst)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		d.readDeploys(ctx)
		t.Reset(deployEvery)
	}
}

// startDeploys starts the poll.
func (d *Daemon) startDeploys() { d.goLoop("waiting deploys", d.readDeploysEvery) }
