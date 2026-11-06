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

// fakeMilestones is the forge's milestones, parents and sub-issues, by issue ref, and how
// often each was asked.
type fakeMilestones struct {
	mu       sync.Mutex
	of       map[string]int
	parents  map[string]string
	children map[string][]string
	asked    map[string]int
}

func (f *fakeMilestones) lookup(_ context.Context, _ string, repo forgeRepo, n int) (issueOnForge, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	ref := repo.issue(n).Ref
	f.asked[ref]++
	m, ok := f.of[ref]
	if !ok {
		return issueOnForge{}, errNoForgeInTests
	}
	got := issueOnForge{milestone: m}
	if p := f.parents[ref]; p != "" {
		got.parent = wire.LineageNode{Kind: "issue", Ref: p}
	}
	for _, c := range f.children[ref] {
		got.children = append(got.children, wire.LineageNode{Kind: "issue", Ref: c})
	}
	return got, nil
}

func (f *fakeMilestones) setParent(ref, parent string) {
	f.mu.Lock()
	if f.parents == nil {
		f.parents = map[string]string{}
	}
	f.parents[ref] = parent
	f.mu.Unlock()
}

func (f *fakeMilestones) set(ref string, m int) {
	f.mu.Lock()
	f.of[ref] = m
	f.mu.Unlock()
}

func (f *fakeMilestones) times(ref string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.asked[ref]
}

// settleMilestones waits for the linker's work, which gives the lookups, then the lookups,
// then their links.
func settleMilestones(t *testing.T, d *Daemon) {
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
			t.Fatalf("%d milestone lookups still wait", waiting)
		}
		time.Sleep(10 * time.Millisecond)
	}
	d.lineageSettle(5 * time.Second)
}

// #2935: a session's #n and a PR's fixes are each part of their milestone on the forge,
// asked once within milestoneRecheck; a move ends the old link and starts a new one.
func TestLineageLinksEachIssueToItsMilestone(t *testing.T) {
	clock := atTime(t, time.Date(2026, 10, 30, 9, 0, 0, 0, time.UTC))
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	forge := &fakeMilestones{of: map[string]int{"github:alexec/agents#12": 15, "github:alexec/agents#7": 15}, asked: map[string]int{}}
	d.issueLookup = forge.lookup
	issue := wire.LineageNode{Kind: "issue", Ref: "github:alexec/agents#12"}

	a := seeded(t, d, folder, func(a *wire.Agent) {
		a.Labels = []wire.SessionLabel{{Value: "#12", Owner: wire.SessionLabelOwnerPerson}, {Value: "ENG-4", Owner: wire.SessionLabelOwnerPerson}}
	})
	d.noteLineage(nil, a)
	settleMilestones(t, d)
	s := sessionNode(a.ID)
	wantLinks(t, active(d, issue),
		s.Ref+" works-on "+issue.Ref+" (start)",
		issue.Ref+" part-of github:alexec/agents/milestone/15 (forge)")

	// Named again within the hour: not asked again.
	payload := `{"pr":{"number":9,"url":"https://github.com/alexec/Agents/pull/9","fixes":["#12","#7","Other/Repo#3"]}}`
	d.lineageEvent(wire.Event{Name: "pr.opened", Details: map[string]string{"payload": payload}})
	settleMilestones(t, d)
	if n := forge.times(issue.Ref); n != 1 {
		t.Fatalf("#12 was asked %d times, want 1", n)
	}
	wantLinks(t, active(d, wire.LineageNode{Kind: "milestone", Ref: "github:alexec/agents/milestone/15"}),
		issue.Ref+" part-of github:alexec/agents/milestone/15 (forge)",
		"github:alexec/agents#7 part-of github:alexec/agents/milestone/15 (forge)")
	// The forge could not say: no link, and the links stay.
	if got := active(d, wire.LineageNode{Kind: "issue", Ref: "github:other/repo#3"}); len(got) != 1 {
		t.Fatalf("other/repo#3: %v", got)
	}

	// Moved to milestone 16: after the hour, the next mention moves the link.
	forge.set(issue.Ref, 16)
	clock.add(milestoneRecheck + time.Minute)
	d.lineageEvent(wire.Event{Name: "pr.merged", Details: map[string]string{"payload": payload}})
	settleMilestones(t, d)
	wantLinks(t, active(d, issue),
		s.Ref+" works-on "+issue.Ref+" (start)",
		"github:alexec/agents#9 fixes "+issue.Ref+" (pr-body)",
		issue.Ref+" part-of github:alexec/agents/milestone/16 (forge)")

	// Taken out of any milestone: the link ends.
	forge.set(issue.Ref, 0)
	clock.add(milestoneRecheck + time.Minute)
	d.lineageEvent(wire.Event{Name: "pr.merged", Details: map[string]string{"payload": payload}})
	settleMilestones(t, d)
	wantLinks(t, active(d, issue),
		s.Ref+" works-on "+issue.Ref+" (start)",
		"github:alexec/agents#9 fixes "+issue.Ref+" (pr-body)")
}

// #3582: an issue is part of its parent on the forge, and a parent's sub-issues each part of
// it; a move ends the old link, as for a milestone.
func TestLineageLinksEachIssueToItsParent(t *testing.T) {
	clock := atTime(t, time.Date(2026, 11, 5, 9, 0, 0, 0, time.UTC))
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	repo := forgeRepo{"github", "alexec/agents"}
	d.repos = map[string]forgeRepo{folder: repo}
	forge := &fakeMilestones{
		of:       map[string]int{"github:alexec/agents#12": 0, "github:alexec/agents#1": 0},
		parents:  map[string]string{"github:alexec/agents#12": "github:alexec/agents#1"},
		children: map[string][]string{"github:alexec/agents#1": {"github:alexec/agents#12", "github:alexec/agents#13"}},
		asked:    map[string]int{},
	}
	d.issueLookup = forge.lookup
	child, epic := repo.issue(12), repo.issue(1)

	d.noteIssueMilestone(folder, repo, 12)
	d.noteIssueMilestone(folder, repo, 1)
	settleMilestones(t, d)
	wantLinks(t, active(d, epic),
		child.Ref+" part-of "+epic.Ref+" (forge)",
		"github:alexec/agents#13 part-of "+epic.Ref+" (forge)")

	// Moved under #2: after the hour, the next lookup moves the link.
	forge.setParent(child.Ref, "github:alexec/agents#2")
	clock.add(milestoneRecheck + time.Minute)
	d.noteIssueMilestone(folder, repo, 12)
	settleMilestones(t, d)
	wantLinks(t, active(d, child), child.Ref+" part-of github:alexec/agents#2 (forge)")

	// No parent now: the link ends.
	forge.setParent(child.Ref, "")
	clock.add(milestoneRecheck + time.Minute)
	d.noteIssueMilestone(folder, repo, 12)
	settleMilestones(t, d)
	wantLinks(t, active(d, child))
}

func TestIssueOnForgeOf(t *testing.T) {
	got, subs, err := issueOnForgeOf([]byte(`{"number":3582,"milestone":null,` +
		`"parent_issue_url":"https://api.github.com/repos/alexec/Agents/issues/3579","sub_issues_summary":{"total":0}}`))
	if err != nil || got.parent.Ref != "github:alexec/agents#3579" || subs != 0 || got.milestone != 0 {
		t.Errorf("a sub-issue: %+v, %d, %v", got, subs, err)
	}
	got, subs, err = issueOnForgeOf([]byte(`{"number":3579,"milestone":{"number":9},"parent_issue_url":null,"sub_issues_summary":{"total":8}}`))
	if err != nil || got.parent != (wire.LineageNode{}) || subs != 8 || got.milestone != 9 {
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

func TestIssueMilestoneOf(t *testing.T) {
	for body, want := range map[string]int{
		`{"number":12,"milestone":{"number":15,"title":"0.14"}}`: 15,
		`{"iid":3,"milestone":{"id":900,"iid":4}}`:               4,
		`{"number":12,"milestone":null}`:                         0,
		`{"number":12}`:                                          0,
	} {
		if got, err := issueMilestoneOf([]byte(body)); err != nil || got != want {
			t.Errorf("%s: got %d, %v; want %d", body, got, err, want)
		}
	}
	if _, err := issueMilestoneOf([]byte("not json")); err == nil {
		t.Error("not json: want an error")
	}
	if n := (forgeRepo{"gitlab", "group/sub/project"}).milestone(4).Ref; n != "gitlab:group/sub/project/milestone/4" {
		t.Errorf("gitlab milestone: %s", n)
	}
}
