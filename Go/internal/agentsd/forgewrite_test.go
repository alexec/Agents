package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/wire"
)

// The fakes' writes (#3130): each says what it was asked in wrote.

func (f *fakeForgeGitHub) note(format string, args ...any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.wrote = append(f.wrote, fmt.Sprintf(format, args...))
}

func (f *fakeForgeGitHub) writes() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.wrote)
}

func (f *fakeForgeGitHub) CommentOnPR(_ context.Context, repo string, number int, words string) (map[string]any, error) {
	f.note("comment %s#%d %s", repo, number, words)
	return map[string]any{"url": "https://github.com/" + repo + "/issues/1#issuecomment-9"}, nil
}

func (f *fakeForgeGitHub) SetLabels(_ context.Context, repo string, number int, add, remove []string) error {
	f.note("labels %s#%d +%s -%s", repo, number, strings.Join(add, ","), strings.Join(remove, ","))
	return nil
}

func (f *fakeForgeGitHub) SetState(_ context.Context, repo string, number int, closed bool) error {
	f.note("state %s#%d closed=%v", repo, number, closed)
	return nil
}

func (f *fakeForgeGitHub) MergeBy(_ context.Context, repo string, number int, sha, method string, auto bool) (map[string]any, error) {
	f.note("merge %s#%d %s %s auto=%v", repo, number, sha, method, auto)
	return map[string]any{"url": "https://github.com/" + repo + "/pull/12"}, nil
}

func (f *fakeForgeGitHub) ReviewPR(_ context.Context, repo string, number int, sha string, approve bool, _ string) (map[string]any, error) {
	f.note("review %s#%d %s approve=%v", repo, number, sha, approve)
	return map[string]any{}, nil
}

func (f *fakeForgeGitHub) RerunFailed(_ context.Context, repo string, runID int) (map[string]any, error) {
	f.note("rerun %s %d", repo, runID)
	return map[string]any{"url": fmt.Sprintf("https://github.com/%s/actions/runs/%d", repo, runID)}, nil
}

func (f *fakeForgeGitHub) FailedLog(_ context.Context, repo string, runID int, job string) (string, error) {
	f.note("log %s %d %s", repo, runID, job)
	return fmt.Sprintf("== %s ==\nboom", job), nil
}

func (f *fakeForgeGitHub) PRDiff(_ context.Context, repo string, number int, _ string) (map[string]any, error) {
	return map[string]any{"url": "https://github.com/" + repo + "/pull/12/files", "headSha": "abc", "cut": false, "files": []any{
		map[string]any{"path": "a.go", "change": "modified", "additions": 1, "deletions": 0,
			"hunks": []githubmcp.Hunk{{OldStart: 1, NewStart: 1, Lines: []githubmcp.DiffLine{{Kind: "added", Text: "x"}}}}},
	}}, nil
}

func (f *fakeForgeGitHub) RepoLabels(context.Context, string) ([]string, map[string]string, error) {
	return []string{"bug", "enhancement"}, map[string]string{"bug": "#d73a4a"}, nil
}

func (f *fakeForgeGitLab) note(format string, args ...any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.wrote = append(f.wrote, fmt.Sprintf(format, args...))
}

func (f *fakeForgeGitLab) Comment(_ context.Context, project string, number int, mr bool, body string) error {
	f.note("comment %s %d mr=%v %s", project, number, mr, body)
	return nil
}

func (f *fakeForgeGitLab) SetLabels(_ context.Context, project string, number int, mr bool, add, remove []string) error {
	f.note("labels %s %d mr=%v +%s -%s", project, number, mr, strings.Join(add, ","), strings.Join(remove, ","))
	return nil
}

func (f *fakeForgeGitLab) SetState(_ context.Context, project string, number int, mr, closed bool) error {
	f.note("state %s %d mr=%v closed=%v", project, number, mr, closed)
	return nil
}

func (f *fakeForgeGitLab) MergeMethods(context.Context, string) ([]string, error) {
	return []string{"merge", "squash"}, nil
}

func (f *fakeForgeGitLab) Merge(_ context.Context, project string, number int, sha string, squash, auto bool) error {
	f.note("merge %s %d %s squash=%v auto=%v", project, number, sha, squash, auto)
	return nil
}

func (f *fakeForgeGitLab) Approve(_ context.Context, project string, number int, sha string) (map[string]any, error) {
	f.note("approve %s %d %s", project, number, sha)
	return map[string]any{}, nil
}

func (f *fakeForgeGitLab) RetryPipeline(_ context.Context, project string, pipelineID int) (map[string]any, error) {
	f.note("retry %s %d", project, pipelineID)
	return map[string]any{}, nil
}

func (f *fakeForgeGitLab) FailedLog(_ context.Context, project string, pipelineID int, job string) (string, error) {
	f.note("log %s %d %s", project, pipelineID, job)
	return "boom", nil
}

func (f *fakeForgeGitLab) MRDiff(context.Context, string, int) (map[string]any, error) {
	return map[string]any{"files": []any{}, "cut": false}, nil
}

func (f *fakeForgeGitLab) ProjectLabels(context.Context, string) ([]string, map[string]string, error) {
	return []string{"bug"}, nil, nil
}

func (f *fakeForgeLinear) note(format string, args ...any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.wrote = append(f.wrote, fmt.Sprintf(format, args...))
}

func (f *fakeForgeLinear) Comment(_ context.Context, identifier, body string) (string, error) {
	f.note("comment %s %s", identifier, body)
	return "https://linear.app/c/1", nil
}

func (f *fakeForgeLinear) SetLabels(_ context.Context, identifier string, add, remove []string) error {
	f.note("labels %s +%s -%s", identifier, strings.Join(add, ","), strings.Join(remove, ","))
	return nil
}

func (f *fakeForgeLinear) SetState(_ context.Context, identifier string, closed bool) error {
	f.note("state %s closed=%v", identifier, closed)
	return nil
}

func (f *fakeForgeLinear) Labels(context.Context, string) ([]string, map[string]string, error) {
	return []string{"Bug"}, nil, nil
}

var (
	ghIssue = wire.LineageNode{Kind: "issue", Ref: "github:alexec/agents#7"}
	ghPull  = wire.LineageNode{Kind: "pr", Ref: "github:alexec/agents#12"}
)

// #3130: an issue's comment, labels and close go to GitHub with the host's connection; a write
// forgets what the reads kept, so the page's next read shows it.
func TestForgeIssueWritesGoToGitHub(t *testing.T) {
	_, c, gh, _ := forgeDaemon(t)
	c.call(t, 1, "forge/issue", wire.ForgeItemRequest{Node: ghIssue})
	_, before := gh.asked()

	var done wire.ForgeDone
	json.Unmarshal(c.call(t, 2, "forge/comment", wire.ForgeCommentRequest{Node: ghIssue, Body: "  Looks good.  "}), &done)
	if deref(done.URL) == "" {
		t.Fatalf("comment: %+v", done)
	}
	c.call(t, 3, "forge/label", wire.ForgeLabelRequest{Node: ghIssue, Add: []string{"bug", " bug "}, Remove: []string{"odd"}})
	c.call(t, 4, "forge/close", wire.ForgeCloseRequest{Node: ghIssue})
	c.call(t, 5, "forge/close", wire.ForgeCloseRequest{Node: ghIssue, Reopen: new(true)})
	want := []string{"comment alexec/agents#7 Looks good.", "labels alexec/agents#7 +bug -odd",
		"state alexec/agents#7 closed=true", "state alexec/agents#7 closed=false"}
	if got := gh.writes(); !slices.Equal(got, want) {
		t.Fatalf("writes:\n%q\nwant\n%q", got, want)
	}

	c.call(t, 6, "forge/issue", wire.ForgeItemRequest{Node: ghIssue})
	if _, after := gh.asked(); after != before+1 {
		t.Fatalf("the read after a write was the kept one: %d reads, then %d", before, after)
	}

	var labels wire.ForgeLabels
	json.Unmarshal(c.call(t, 7, "forge/labels", wire.ForgeNodeRequest{Node: ghIssue}), &labels)
	if len(labels.Labels) != 2 || deref(labels.Labels[0].Color) != "#d73a4a" {
		t.Fatalf("labels: %+v", labels)
	}
}

// #3130: an issue's page brings the new-agent form for Start Agent, as the issues view fills it.
func TestForgeIssueBringsStartAgent(t *testing.T) {
	_, c, _, _ := forgeDaemon(t)
	var got wire.ForgeItemDetail
	json.Unmarshal(c.call(t, 1, "forge/issue", wire.ForgeItemRequest{Node: ghIssue}), &got)
	s := got.Start
	if s == nil || !strings.Contains(s.Prompt, "gh issue view 7 --repo alexec/agents") || !slices.Equal(s.Labels, []string{"#7"}) ||
		deref(s.Worktree) != "7 Forge reads" {
		t.Fatalf("start: %+v", s)
	}
	var pull wire.ForgeItemDetail
	json.Unmarshal(c.call(t, 2, "forge/pull", wire.ForgeItemRequest{Node: ghPull}), &pull)
	if pull.Start != nil || deref(pull.Head) != "abc" || len(pull.MergeMethods) != 3 || pull.MergeMethods[0] != wire.ForgeMergeMethodSquash {
		t.Fatalf("a pull request has its head and merge methods, and no Start Agent: %+v", pull)
	}
}

// #3130: a pull request merges at the head the page showed, by the repo's default method when
// none is said; approve names the head; rerun and the log take the failing checks' Actions runs.
func TestForgePullWritesGoToGitHub(t *testing.T) {
	_, c, gh, _ := forgeDaemon(t)
	c.call(t, 1, "forge/merge", wire.ForgeMergeRequest{Node: ghPull, Sha: "abc"})
	rebase := wire.ForgeMergeMethodRebase
	var done wire.ForgeDone
	json.Unmarshal(c.call(t, 2, "forge/merge", wire.ForgeMergeRequest{Node: ghPull, Sha: "abc", Method: &rebase, Auto: new(true)}), &done)
	if done.Auto == nil || !*done.Auto {
		t.Fatalf("auto-merge: %+v", done)
	}
	c.call(t, 3, "forge/approve", wire.ForgeApproveRequest{Node: ghPull, Sha: "abc"})
	json.Unmarshal(c.call(t, 4, "forge/rerun", wire.ForgeNodeRequest{Node: ghPull}), &done)
	if done.Reran == nil || *done.Reran != 1 {
		t.Fatalf("rerun: %+v", done)
	}
	var log wire.ForgeLog
	json.Unmarshal(c.call(t, 5, "forge/log", wire.ForgeLogRequest{Node: ghPull, Check: new("test")}), &log)
	if !strings.Contains(log.Text, "boom") {
		t.Fatalf("log: %+v", log)
	}
	want := []string{"merge alexec/agents#12 abc squash auto=false", "merge alexec/agents#12 abc rebase auto=true",
		"review alexec/agents#12 abc approve=true", "rerun alexec/agents 1", "log alexec/agents 1 test"}
	if got := gh.writes(); !slices.Equal(got, want) {
		t.Fatalf("writes:\n%q\nwant\n%q", got, want)
	}

	var diff wire.ForgeDiff
	json.Unmarshal(c.call(t, 6, "forge/diff", wire.ForgeNodeRequest{Node: ghPull}), &diff)
	if len(diff.Files) != 1 || diff.Files[0].Path != "a.go" || len(diff.Files[0].Hunks) != 1 ||
		diff.Files[0].Hunks[0].Lines[0].Kind != wire.DiffLineKindAdded || deref(diff.URL) == "" {
		t.Fatalf("diff: %+v", diff)
	}
}

// #3130: a write says what is wrong with it, and asks the forge nothing: an empty comment, no
// label, a merge with no head, a pull request's action on an issue, a forge it does not know.
func TestForgeWritesRefuseWhatIsWrong(t *testing.T) {
	_, c, gh, _ := forgeDaemon(t)
	for i, ask := range []struct {
		method string
		params any
	}{
		{"forge/comment", wire.ForgeCommentRequest{Node: ghIssue, Body: "  "}},
		{"forge/label", wire.ForgeLabelRequest{Node: ghIssue, Add: []string{" "}}},
		{"forge/merge", wire.ForgeMergeRequest{Node: ghPull}},
		{"forge/approve", wire.ForgeApproveRequest{Node: ghIssue, Sha: "abc"}},
		{"forge/rerun", wire.ForgeNodeRequest{Node: ghIssue}},
		{"forge/close", wire.ForgeCloseRequest{Node: wire.LineageNode{Kind: "issue", Ref: "bitbucket:X-1"}}},
	} {
		if e := c.callError(t, 10+i, ask.method, ask.params); e == nil || !strings.Contains(e.Message, ask.method) {
			t.Fatalf("%s: %v", ask.method, e)
		}
	}
	if got := gh.writes(); len(got) != 0 {
		t.Fatalf("a refused write asked GitHub: %q", got)
	}
}

// #3130: an agent's connection may call none of the writes: a person writes, from their own page.
func TestForgeWritesAreNotAnAgents(t *testing.T) {
	for _, m := range []string{"forge/comment", "forge/label", "forge/close", "forge/merge", "forge/approve", "forge/rerun"} {
		if RoleAgent.Allows(m) {
			t.Fatalf("an agent may call %s", m)
		}
	}
}

// #3130: GitLab and Linear take the same writes: a merge request's merge by the project's
// methods (no rebase), its retry and log of the head pipeline; a Linear issue's comment, labels
// and close; a merge on Linear is refused.
func TestForgeWritesGoToGitLabAndLinear(t *testing.T) {
	_, c, _, gl, ln, _ := allForgesDaemon(t)
	mr := wire.LineageNode{Kind: "pr", Ref: "gitlab:group/app!4"}
	c.call(t, 1, "forge/comment", wire.ForgeCommentRequest{Node: mr, Body: "Fine."})
	c.call(t, 2, "forge/merge", wire.ForgeMergeRequest{Node: mr, Sha: "head4"})
	squash, rebase := wire.ForgeMergeMethodSquash, wire.ForgeMergeMethodRebase
	c.call(t, 3, "forge/merge", wire.ForgeMergeRequest{Node: mr, Sha: "head4", Method: &squash, Auto: new(true)})
	if e := c.callError(t, 4, "forge/merge", wire.ForgeMergeRequest{Node: mr, Sha: "head4", Method: &rebase}); e == nil {
		t.Fatal("GitLab merged by rebase")
	}
	c.call(t, 5, "forge/approve", wire.ForgeApproveRequest{Node: mr, Sha: "head4"})
	c.call(t, 6, "forge/rerun", wire.ForgeNodeRequest{Node: mr})
	c.call(t, 7, "forge/log", wire.ForgeLogRequest{Node: mr, Check: new("check: test")})
	gl.mu.Lock()
	got := slices.Clone(gl.wrote)
	gl.mu.Unlock()
	want := []string{"comment Group/App 4 mr=true Fine.", "merge Group/App 4 head4 squash=false auto=false",
		"merge Group/App 4 head4 squash=true auto=true", "approve Group/App 4 head4", "retry Group/App 99", "log Group/App 99 test"}
	if !slices.Equal(got, want) {
		t.Fatalf("GitLab writes:\n%q\nwant\n%q", got, want)
	}

	eng := wire.LineageNode{Kind: "issue", Ref: "linear:ENG-4"}
	c.call(t, 10, "forge/comment", wire.ForgeCommentRequest{Node: eng, Body: "Done."})
	c.call(t, 11, "forge/label", wire.ForgeLabelRequest{Node: eng, Add: []string{"Bug"}})
	c.call(t, 12, "forge/close", wire.ForgeCloseRequest{Node: eng})
	if e := c.callError(t, 13, "forge/merge", wire.ForgeMergeRequest{Node: eng, Sha: "x"}); e == nil {
		t.Fatal("a Linear issue merged")
	}
	ln.mu.Lock()
	got = slices.Clone(ln.wrote)
	ln.mu.Unlock()
	want = []string{"comment ENG-4 Done.", "labels ENG-4 +Bug -", "state ENG-4 closed=true"}
	if !slices.Equal(got, want) {
		t.Fatalf("Linear writes:\n%q\nwant\n%q", got, want)
	}
}
