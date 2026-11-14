package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"testing"

	"github.com/agentloops-dev/agents/Go/internal/connections"
	"github.com/agentloops-dev/agents/Go/internal/githubmcp"
	"github.com/agentloops-dev/agents/Go/wire"
)

func (f *fakeForgeGitHub) WaitingDeploys(_ context.Context, repo, _, _ string) ([]githubmcp.WaitingDeploy, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.waiting[repo]), nil
}

func (f *fakeForgeGitHub) Tags(context.Context, string) ([]string, error) {
	return []string{"v0.17.0", "v0.15.0", "latest", "v0.16.0"}, nil
}

func (f *fakeForgeGitHub) Compare(_ context.Context, repo, base, head string) ([]githubmcp.Commit, error) {
	if repo != "alexec/agents" || base != "v0.16.0" || head != "v0.17.0" {
		return nil, fmt.Errorf("compare %s %s...%s", repo, base, head)
	}
	return []githubmcp.Commit{{SHA: "a1", Message: "Waiting deploys in Needs You (#3587)\n\nThe body."}, {SHA: "a2", Message: "Sentry health (#3585)"}}, nil
}

func (f *fakeForgeGitHub) ReviewDeployments(_ context.Context, repo string, runID int, environments []int64, approve bool, comment string) error {
	f.note("deploy %s %d %v %t %s", repo, runID, environments, approve, comment)
	return f.deployErr
}

// waitingRelease is a tag's release.yml run waiting for production's reviewers.
func waitingRelease(id int, canApprove bool) githubmcp.WaitingDeploy {
	return githubmcp.WaitingDeploy{
		Run: githubmcp.CompletedRun{Run: githubmcp.RunRef{ID: id, Attempt: 1, Name: "Release", Branch: "v0.17.0", HeadSHA: "abc",
			URL: "https://github.com/alexec/agents/actions/runs/77", UpdatedAt: "2026-11-05T10:00:00Z"}, Workflow: "release.yml"},
		Environments: []githubmcp.Environment{{ID: 11, Name: "production"}},
		Reviewers:    []string{"alexec"}, CanApprove: canApprove,
	}
}

// deployApprovalsIn is the deploys Needs You lists for the folder on repo, and that folder.
func deployApprovalsIn(d *Daemon, repo string) ([]wire.Approval, string) {
	for _, f := range d.folderPaths() {
		if d.folderRepo(f).path != repo {
			continue
		}
		s, _ := d.summaryFor(f)
		var out []wire.Approval
		for _, a := range s.Approvals {
			if a.Kind == wire.ApprovalKindDeploy {
				out = append(out, a)
			}
		}
		if len(out) > 0 {
			return out, f
		}
	}
	return nil, ""
}

// #3587: a run waiting for an environment's reviewers is a Needs You approval of its repo's
// folder while the person may approve it; its reading says what ships since the version tag
// before; an answer to another wait, or Request Changes, is refused; Approve answers GitHub as
// the person, and takes it out of the list.
func TestWaitingDeployIsAnApprovalAnsweredOnGitHub(t *testing.T) {
	d, c, gh, _ := forgeDaemon(t)
	gh.waiting = map[string][]githubmcp.WaitingDeploy{
		"alexec/agents": {waitingRelease(77, true)},
		"alexec/web":    {waitingRelease(78, false)},
	}
	d.readDeploys(d.ctx)

	got, folder := deployApprovalsIn(d, "alexec/agents")
	if len(got) != 1 {
		t.Fatalf("approvals: %+v", got)
	}
	a := got[0]
	if a.Key != "alexec/agents/77" || a.Title != "Release to production" || a.Line != "v0.17.0 waits for your approval" ||
		deref(a.Digest) != "1:11" || a.Since == nil || !slices.Equal(a.Actions, []wire.ApprovalAction{wire.ApprovalActionApprove, wire.ApprovalActionDeny}) {
		t.Fatalf("approval: %+v", a)
	}
	if web, _ := deployApprovalsIn(d, "alexec/web"); len(web) != 0 {
		t.Fatalf("one the person may not approve: %+v", web)
	}

	url := wire.URL("file://" + folder)
	var reading wire.GuardedChangeReading
	json.Unmarshal(c.call(t, 1, "approvals/read", wire.ApprovalReadRequest{Folder: url, Kind: wire.ApprovalKindDeploy, Key: a.Key}), &reading)
	var texts []string
	for _, l := range reading.Lines {
		texts = append(texts, string(l.Kind)+" "+l.Text)
	}
	if reading.Path != "alexec/agents v0.17.0" || deref(reading.Digest) != "1:11" || !slices.Equal(texts, []string{
		"same Run: Release, attempt 1, https://github.com/alexec/agents/actions/runs/77",
		"same Waits for: production",
		"same Reviewers: alexec",
		"same Commit: abc",
		"same Ships since v0.16.0: 2 commits",
		"added Waiting deploys in Needs You (#3587)",
		"added Sentry health (#3585)",
	}) {
		t.Fatalf("reading: %s %q", reading.Path, texts)
	}

	stale := "2:11"
	if e := c.callError(t, 2, "approvals/answer", wire.ApprovalAnswer{Folder: url, Kind: wire.ApprovalKindDeploy, Key: a.Key,
		Digest: &stale, Action: wire.ApprovalActionApprove}); e.Code != wire.FailureNotChanged {
		t.Fatalf("another wait: %+v", e)
	}
	if e := c.callError(t, 3, "approvals/answer", wire.ApprovalAnswer{Folder: url, Kind: wire.ApprovalKindDeploy, Key: a.Key,
		Digest: a.Digest, Action: wire.ApprovalActionRequestChanges, Note: new("later")}); e == nil {
		t.Fatal("Request Changes")
	}
	if w := gh.writes(); len(w) != 0 {
		t.Fatalf("answered GitHub: %q", w)
	}
	var s wire.FolderSummary
	json.Unmarshal(c.call(t, 4, "approvals/answer", wire.ApprovalAnswer{Folder: url, Kind: wire.ApprovalKindDeploy, Key: a.Key,
		Digest: a.Digest, Action: wire.ApprovalActionApprove}), &s)
	if w := gh.writes(); !slices.Equal(w, []string{"deploy alexec/agents 77 [11] true Approved in Agent Loops"}) {
		t.Fatalf("writes: %q", w)
	}
	for _, x := range s.Approvals {
		if x.Kind == wire.ApprovalKindDeploy {
			t.Fatalf("still listed: %+v", s.Approvals)
		}
	}

	// GitHub says no more waits: none is listed.
	gh.mu.Lock()
	gh.waiting = nil
	gh.mu.Unlock()
	d.readDeploys(d.ctx)
	if left, _ := deployApprovalsIn(d, "alexec/agents"); len(left) != 0 {
		t.Fatalf("after the run went on: %+v", left)
	}
}

// #3587: with no GitHub connection, no deploy waits in Needs You.
func TestWaitingDeploysNeedAConnection(t *testing.T) {
	d, _, gh, file := forgeDaemon(t)
	gh.waiting = map[string][]githubmcp.WaitingDeploy{"alexec/agents": {waitingRelease(77, true)}}
	d.readDeploys(d.ctx)
	if got, _ := deployApprovalsIn(d, "alexec/agents"); len(got) != 1 {
		t.Fatalf("connected: %+v", got)
	}
	file.Delete(connections.GitHub)
	d.readDeploys(d.ctx)
	if got, _ := deployApprovalsIn(d, "alexec/agents"); len(got) != 0 {
		t.Fatalf("not connected: %+v", got)
	}
}

// #3932: GitHub's 403 to an answer says what the App needs, and the deploy stays listed.
func TestRefusedDeployAnswerSaysWhatGitHubNeeds(t *testing.T) {
	d, c, gh, _ := forgeDaemon(t)
	gh.waiting = map[string][]githubmcp.WaitingDeploy{"alexec/agents": {waitingRelease(77, true)}}
	gh.deployErr = &githubmcp.GitHubError{Kind: githubmcp.Failed, Message: "GitHub: HTTP 403", Refused: true}
	d.readDeploys(d.ctx)
	got, folder := deployApprovalsIn(d, "alexec/agents")
	if len(got) != 1 {
		t.Fatalf("approvals: %+v", got)
	}
	e := c.callError(t, 1, "approvals/answer", wire.ApprovalAnswer{Folder: wire.URL("file://" + folder), Kind: wire.ApprovalKindDeploy,
		Key: got[0].Key, Digest: got[0].Digest, Action: wire.ApprovalActionApprove})
	if e == nil || !strings.Contains(e.Message, "agents-loops app needs the Deployments permission") {
		t.Fatalf("refused: %+v", e)
	}
	if left, _ := deployApprovalsIn(d, "alexec/agents"); len(left) != 1 {
		t.Fatalf("dropped: %+v", left)
	}
}
