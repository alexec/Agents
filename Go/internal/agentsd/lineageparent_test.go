package agentsd

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

var errNoForgeInTests = errors.New("no forge in tests")

// fakeParents is the forge's parents and sub-issues, by issue ref, and how often each was
// asked. An issue not in known is one the forge could not say.
type fakeParents struct {
	mu       sync.Mutex
	known    map[string]bool
	parents  map[string]string
	children map[string][]string
	asked    map[string]int
}

func (f *fakeParents) lookup(_ context.Context, _ string, repo forgeRepo, n int) (issueOnForge, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	ref := repo.issue(n).Ref
	f.asked[ref]++
	if !f.known[ref] {
		return issueOnForge{}, errNoForgeInTests
	}
	got := issueOnForge{}
	if p := f.parents[ref]; p != "" {
		got.parent = wire.LineageNode{Kind: "issue", Ref: p}
	}
	for _, c := range f.children[ref] {
		got.children = append(got.children, wire.LineageNode{Kind: "issue", Ref: c})
	}
	return got, nil
}

func (f *fakeParents) setParent(ref, parent string) {
	f.mu.Lock()
	if f.parents == nil {
		f.parents = map[string]string{}
	}
	f.parents[ref] = parent
	f.mu.Unlock()
}

func (f *fakeParents) times(ref string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.asked[ref]
}

// settleParents waits for the linker's work, which gives the lookups, then the lookups, then
// their links.
func settleParents(t *testing.T, d *Daemon) {
	t.Helper()
	d.lineageSettle(5 * time.Second)
	for deadline := time.Now().Add(5 * time.Second); ; {
		d.issueMu.Lock()
		waiting := len(d.issueWaiting)
		d.issueMu.Unlock()
		if waiting == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("%d parent lookups still wait", waiting)
		}
		time.Sleep(10 * time.Millisecond)
	}
	d.lineageSettle(5 * time.Second)
}

// A session's #n and a PR's fixes are each asked for their parent once within parentRecheck;
// an issue on another forge is not asked, and an issue the forge could not say keeps its links.
func TestLineageAsksEachGitHubIssueOnce(t *testing.T) {
	atTime(t, time.Date(2026, 10, 30, 9, 0, 0, 0, time.UTC))
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	forge := &fakeParents{known: map[string]bool{"github:alexec/agents#12": true, "github:alexec/agents#7": true},
		parents: map[string]string{"github:alexec/agents#12": "github:alexec/agents#1"}, asked: map[string]int{}}
	d.issueLookup = forge.lookup
	issue := wire.LineageNode{Kind: "issue", Ref: "github:alexec/agents#12"}

	a := seeded(t, d, folder, func(a *wire.Agent) {
		a.Labels = []wire.SessionLabel{{Value: "#12", Owner: wire.SessionLabelOwnerPerson}, {Value: "ENG-4", Owner: wire.SessionLabelOwnerPerson}}
	})
	d.noteLineage(nil, a)
	settleParents(t, d)
	s := sessionNode(a.ID)
	wantLinks(t, active(d, issue),
		s.Ref+" works-on "+issue.Ref+" (start)",
		issue.Ref+" part-of github:alexec/agents#1 (forge)")

	// Named again within the hour: not asked again.
	payload := `{"pr":{"number":9,"url":"https://github.com/alexec/Agents/pull/9","fixes":["#12","#7","Other/Repo#3"]}}`
	d.lineageEvent(wire.Event{Name: "pr.opened", Details: map[string]string{"payload": payload}})
	settleParents(t, d)
	if n := forge.times(issue.Ref); n != 1 {
		t.Fatalf("#12 was asked %d times, want 1", n)
	}
	if n := forge.times("github:alexec/agents#7"); n != 1 {
		t.Fatalf("#7 was asked %d times, want 1", n)
	}
	// The forge could not say: no link, and the links stay.
	if got := active(d, wire.LineageNode{Kind: "issue", Ref: "github:other/repo#3"}); len(got) != 1 {
		t.Fatalf("other/repo#3: %v", got)
	}
	// GitLab says no parent: not asked.
	d.noteIssueParent(folder, forgeRepo{"gitlab", "group/project"}, 4)
	settleParents(t, d)
	if n := forge.times("gitlab:group/project#4"); n != 0 {
		t.Fatalf("a GitLab issue was asked %d times, want 0", n)
	}
}

// #3582: an issue is part of its parent on the forge, and a parent's sub-issues each part of
// it; a move ends the old link and starts a new one.
func TestLineageLinksEachIssueToItsParent(t *testing.T) {
	clock := atTime(t, time.Date(2026, 11, 5, 9, 0, 0, 0, time.UTC))
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	repo := forgeRepo{"github", "alexec/agents"}
	d.repos = map[string]forgeRepo{folder: repo}
	forge := &fakeParents{
		known:    map[string]bool{"github:alexec/agents#12": true, "github:alexec/agents#1": true},
		parents:  map[string]string{"github:alexec/agents#12": "github:alexec/agents#1"},
		children: map[string][]string{"github:alexec/agents#1": {"github:alexec/agents#12", "github:alexec/agents#13"}},
		asked:    map[string]int{},
	}
	d.issueLookup = forge.lookup
	child, epic := repo.issue(12), repo.issue(1)

	d.noteIssueParent(folder, repo, 12)
	d.noteIssueParent(folder, repo, 1)
	settleParents(t, d)
	wantLinks(t, active(d, epic),
		child.Ref+" part-of "+epic.Ref+" (forge)",
		"github:alexec/agents#13 part-of "+epic.Ref+" (forge)")

	// Moved under #2: after the hour, the next lookup moves the link.
	forge.setParent(child.Ref, "github:alexec/agents#2")
	clock.add(parentRecheck + time.Minute)
	d.noteIssueParent(folder, repo, 12)
	settleParents(t, d)
	wantLinks(t, active(d, child), child.Ref+" part-of github:alexec/agents#2 (forge)")

	// No parent now: the link ends.
	forge.setParent(child.Ref, "")
	clock.add(parentRecheck + time.Minute)
	d.noteIssueParent(folder, repo, 12)
	settleParents(t, d)
	wantLinks(t, active(d, child))
}

func TestIssueOnForgeOf(t *testing.T) {
	got, subs, err := issueOnForgeOf([]byte(`{"number":3582,` +
		`"parent_issue_url":"https://api.github.com/repos/alexec/Agents/issues/3579","sub_issues_summary":{"total":0}}`))
	if err != nil || got.parent.Ref != "github:alexec/agents#3579" || subs != 0 {
		t.Errorf("a sub-issue: %+v, %d, %v", got, subs, err)
	}
	got, subs, err = issueOnForgeOf([]byte(`{"number":3579,"parent_issue_url":null,"sub_issues_summary":{"total":8}}`))
	if err != nil || got.parent != (wire.LineageNode{}) || subs != 8 {
		t.Errorf("an epic: %+v, %d, %v", got, subs, err)
	}
	children, err := subIssuesOf([]byte(`[{"html_url":"https://github.com/alexec/Agents/issues/3581"},{"html_url":"https://github.com/Other/Repo/issues/7"}]`))
	if err != nil || len(children) != 2 || children[0].Ref != "github:alexec/agents#3581" || children[1].Ref != "github:other/repo#7" {
		t.Errorf("sub-issues: %v, %v", children, err)
	}
	for raw, want := range map[string]string{
		"https://github.com/alexec/Agents/issues/12":                "github:alexec/agents#12",
		"https://gitlab.com/group/sub/project/-/issues/4":           "gitlab:group/sub/project#4",
		"https://github.com/alexec/Agents/issues/12#issuecomment-1": "github:alexec/agents#12",
		"https://github.com/alexec/Agents/pull/12":                  "",
		"https://gitlab.com/group/project/issues/4":                 "",
		"https://api.github.com/repos/alexec/Agents/issues/12":      "",
		"https://github.com/alexec/Agents/issues/new":               "",
	} {
		got := ""
		if repo, n, ok := issueOfURL(raw); ok {
			got = repo.issue(n).Ref
		}
		if got != want {
			t.Errorf("%s: got %q, want %q", raw, got, want)
		}
	}
}
