package agentsd

import (
	"context"
	"encoding/json"
	"sync"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// fakeResolves is the forge's issues and pull requests, by ref, and how often each was asked.
type fakeResolves struct {
	mu    sync.Mutex
	of    map[string]wire.LineageResolved
	asked map[string]int
}

func (f *fakeResolves) lookup(_ context.Context, _ string, repo forgeRepo, kind string, n int) (wire.LineageResolved, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	ref := repo.issue(n).Ref
	if kind == "pr" {
		ref = repo.pr(n).Ref
	}
	f.asked[ref]++
	r, ok := f.of[ref]
	if !ok {
		return wire.LineageResolved{}, errNoForgeInTests
	}
	return r, nil
}

func (f *fakeResolves) times(ref string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.asked[ref]
}

// #3089: lineage/walk resolves a GitHub issue's and pull request's title, state and labels
// from the forge, cached so a second walk within resolveRecheck does not ask again.
func TestLineageWalkResolvesForgeNodes(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := t.TempDir()
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	issue := wire.LineageNode{Kind: "issue", Ref: "github:alexec/agents#12"}
	pr := wire.LineageNode{Kind: "pr", Ref: "github:alexec/agents#13"}
	fake := &fakeResolves{asked: map[string]int{}, of: map[string]wire.LineageResolved{
		issue.Ref: {Title: "Resolve a node's title", Labels: []string{"area:lineage"}},
		pr.Ref:    {Title: "Resolve it", Labels: []string{}},
	}}
	d.resolveLookup = fake.lookup

	a := seeded(t, d, folder, func(a *wire.Agent) {
		a.Labels = []wire.SessionLabel{{Value: "#12", Owner: wire.SessionLabelOwnerPerson}}
	})
	s := sessionNode(a.ID)
	c.call(t, 1, "lineage/link", wire.LineageLinkRequest{From: s, To: issue, Rel: "works-on", Source: "start"})
	c.call(t, 2, "lineage/link", wire.LineageLinkRequest{From: s, To: pr, Rel: "opens", Source: "agent"})

	var g wire.LineageGraph
	json.Unmarshal(c.call(t, 3, "lineage/walk", wire.LineageNodeRequest{Node: issue}), &g)
	if r, ok := g.Resolved[issue.Ref]; !ok || r.Title != "Resolve a node's title" || len(r.Labels) != 1 || r.Labels[0] != "area:lineage" {
		t.Fatalf("issue resolved: %+v", g.Resolved[issue.Ref])
	}
	if r, ok := g.Resolved[pr.Ref]; !ok || r.Title != "Resolve it" {
		t.Fatalf("pr resolved: %+v", g.Resolved[pr.Ref])
	}
	if r := g.Resolved[s.Ref]; r.Title != "" {
		t.Fatalf("a session node was resolved: %+v", r)
	}

	// Asked once; a second walk within resolveRecheck uses the cache.
	json.Unmarshal(c.call(t, 4, "lineage/walk", wire.LineageNodeRequest{Node: issue}), &g)
	if n := fake.times(issue.Ref); n != 1 {
		t.Fatalf("%s was asked %d times, want 1", issue.Ref, n)
	}
}

// A node with no folder signed in to its repo is not resolved: nothing is asked, and the
// walk still answers.
func TestLineageWalkSkipsResolvingWithNoFolder(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	issue := wire.LineageNode{Kind: "issue", Ref: "github:alexec/agents#12"}
	c.call(t, 1, "lineage/link", wire.LineageLinkRequest{
		From: wire.LineageNode{Kind: "session", Ref: "session:00000000-0000-0000-0000-000000000001"},
		To:   issue, Rel: "works-on", Source: "start",
	})
	var g wire.LineageGraph
	json.Unmarshal(c.call(t, 2, "lineage/walk", wire.LineageNodeRequest{Node: issue}), &g)
	if len(g.Resolved) != 0 {
		t.Fatalf("resolved with no folder signed in: %+v", g.Resolved)
	}
}

func TestNodeOfRepo(t *testing.T) {
	for ref, kind := range map[string]string{
		"github:alexec/agents#12": "issue",
		"github:alexec/agents#13": "pr",
		"gitlab:group/project#4":  "issue",
		"gitlab:group/project!5":  "pr",
	} {
		repo, n, ok := nodeOfRepo(wire.LineageNode{Kind: kind, Ref: ref})
		if !ok || n <= 0 || repo.forge == "" {
			t.Errorf("%s: got %+v, %d, %v", ref, repo, n, ok)
		}
	}
	for ref, kind := range map[string]string{
		"session:00000000-0000-0000-0000-000000000001": "session",
		"linear:ENG-4":           "issue",
		"github:alexec/agents#0": "issue",
		"github:no-number":      "issue",
	} {
		if _, _, ok := nodeOfRepo(wire.LineageNode{Kind: kind, Ref: ref}); ok {
			t.Errorf("%s: want not resolvable", ref)
		}
	}
}

func TestResolvedOf(t *testing.T) {
	cases := []struct {
		kind, body, title, state string
		labels                   []string
	}{
		{"issue", `{"title":"Fix it","state":"open","labels":[{"name":"bug"},{"name":"area:lineage"}]}`,
			"Fix it", "open", []string{"bug", "area:lineage"}},
		{"pr", `{"title":"Fix it","state":"closed","merged_at":"2026-10-30T00:00:00Z"}`, "Fix it", "merged", nil},
		{"pr", `{"title":"Fix it","state":"closed"}`, "Fix it", "closed", nil},
		{"issue", `{"title":"Fix it","state":"opened","labels":["bug","area:lineage"]}`,
			"Fix it", "open", []string{"bug", "area:lineage"}},
	}
	for _, c := range cases {
		got, err := resolvedOf(c.kind, []byte(c.body))
		if err != nil {
			t.Errorf("%s: %v", c.body, err)
			continue
		}
		state := ""
		if got.State != nil {
			state = *got.State
		}
		if got.Title != c.title || state != c.state || !sameStrings(got.Labels, c.labels) {
			t.Errorf("%s: got %+v", c.body, got)
		}
	}
	if _, err := resolvedOf("issue", []byte(`{"state":"open"}`)); err == nil {
		t.Error("no title: want an error")
	}
	if _, err := resolvedOf("issue", []byte("not json")); err == nil {
		t.Error("not json: want an error")
	}
}

func sameStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
