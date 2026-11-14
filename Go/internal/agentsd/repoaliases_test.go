package agentsd

import (
	"context"
	"encoding/json"
	"maps"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/repoalias"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

func noAliases(t *testing.T) {
	t.Helper()
	repoalias.Set(nil)
	t.Cleanup(func() { repoalias.Set(nil) })
}

// #4957: a wait or a trigger that names the old owner hears an event that names the new
// one, and the other way, by subject, topic and the repo in `where`.
func TestAMovedRepoMatchesByEitherName(t *testing.T) {
	noAliases(t)
	oldPR := wire.Ref{Provider: "github", Type: "pr", Topic: "alexec/agents", ID: "4702"}
	newPR := wire.Ref{Provider: "github", Type: "pr", Topic: "agentloops-dev/agent-loops", ID: "4702"}
	provider, topic := "github", "agentloops-dev/agent-loops"
	e := wire.Event{Name: "pr.merged", Provider: &provider, Topic: &topic, Subject: &newPR,
		Details: map[string]string{"repo": "agentloops-dev/agent-loops", "pr": "4702"}}
	byOld := waitPattern{name: "pr.merged", filters: map[string][]string{"repo": {"alexec/Agents"}, "pr": {"4702"}},
		bus: busFilter{topics: []string{"alexec/agents"}, subject: &oldPR}}
	if byOld.matches(e) {
		t.Fatal("matched by the old name before the alias")
	}
	repoalias.Add("github", "alexec/Agents", "agentloops-dev/agent-loops", nowFunc())
	if !byOld.matches(e) {
		t.Fatal("the old name does not hear the new one's event")
	}
	old := wire.Event{Name: "pr.merged", Provider: &provider, Subject: &oldPR, Details: map[string]string{"repo": "alexec/Agents", "pr": "4702"}}
	byNew := waitPattern{name: "pr.merged", filters: map[string][]string{"repo": {"agentloops-dev/agent-loops"}}, bus: busFilter{subject: &newPR}}
	if !byNew.matches(old) {
		t.Fatal("the new name does not hear the old one's event")
	}
	other := waitPattern{name: "pr.merged", filters: map[string][]string{"repo": {"alexec/other"}}}
	if other.matches(e) {
		t.Fatal("another repo matched")
	}
}

// GitHub's redirect says the new name; the check keeps it, and the lineage names the old
// refs by it.
func TestTheCheckLearnsAMoveFromGitHub(t *testing.T) {
	noAliases(t)
	mux := http.NewServeMux()
	mux.HandleFunc("/repos/alexec/agents", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/repositories/1", http.StatusMovedPermanently)
	})
	mux.HandleFunc("/repositories/1", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"full_name":"agentloops-dev/agent-loops"}`))
	})
	mux.HandleFunc("/repos/alexec/stays", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"full_name":"alexec/stays"}`))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	d, err := New(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	// A daemon left running scans on its clock into a later test's AGENTS_PERSONAL_HOME (#5368).
	t.Cleanup(d.Shutdown)
	d.repoAliasAPI = srv.URL
	pr := wire.LineageNode{Kind: "pr", Ref: "github:pr:alexec/agents#12"}
	for _, to := range []wire.LineageNode{{Kind: "issue", Ref: "github:issue:alexec/agents#1"}, {Kind: "issue", Ref: "github:issue:alexec/stays#2"}} {
		if _, err := d.lineage().Link(wire.LineageLinkRequest{From: pr, To: to, Rel: "fixes", Source: "person"}, nowFunc()); err != nil {
			t.Fatal(err)
		}
	}
	if n := d.checkRepoAliases(context.Background()); n != 1 {
		t.Fatalf("added %d, want 1: %+v", n, repoalias.All())
	}
	if got := repoalias.Topic("github", "alexec/agents"); got != "agentloops-dev/agent-loops" {
		t.Fatalf("alias: %q", got)
	}
	if _, err := os.Stat(d.repoAliasesPath()); err != nil {
		t.Fatal(err)
	}
	if got := d.lineage().Links(wire.LineageNode{Kind: "pr", Ref: "github:pr:agentloops-dev/agent-loops#12"}); len(got.Links) != 2 {
		t.Fatalf("the PR by its new name: %+v", got)
	}
	if n := d.checkRepoAliases(context.Background()); n != 0 {
		t.Fatalf("the second check added %d", n)
	}
}

// #5332: the cost ledger keeps the PRs it banked before the repo moved twice (alexec/agents,
// then agentloops-dev/agents, then agentloops-dev/agent-loops) under the old names, and the
// lineage names their sessions' links by the name now. Each PR is one node by the name now:
// its sessions come back, the Multiplier counts every merge, and a PR banked under two names
// is one merge with both costs.
func TestTheLedgerNamesAMovedRepoByItsNameNow(t *testing.T) {
	noAliases(t)
	repoalias.Add("github", "alexec/agents", "agentloops-dev/agents", nowFunc())
	repoalias.Add("github", "agentloops-dev/agents", "agentloops-dev/agent-loops", nowFunc())
	root := t.TempDir()
	d, err := New(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	// A daemon left running scans on its clock into a later test's AGENTS_PERSONAL_HOME (#5368).
	t.Cleanup(d.Shutdown)
	merged, ended, last := "merged", wire.DateOf(nowFunc()), wire.DateOf(nowFunc())
	earlier, parent := last-3600, "github:issue:alexec/agents#1"
	pr := func(ref string, at wire.Date, cost float64) wire.LineageCostNode {
		repo := "github:repo:#" + ref[len("github:pr:"):strings.IndexByte(ref, '#')]
		return wire.LineageCostNode{Node: wire.LineageNode{Kind: "pr", Ref: ref}, Repo: &repo, Outcome: &merged, EndedAt: &ended,
			LastAt: at, FirstAt: &at, Banked: wire.LineageCost{Cost: map[string]float64{"usd": cost}},
			Parent: &parent}
	}
	nodes := map[string]wire.LineageCostNode{}
	for _, c := range []wire.LineageCostNode{
		pr("github:pr:alexec/agents#1", earlier, 1),
		pr("github:pr:alexec/agents#2", earlier, 1),
		pr("github:pr:agentloops-dev/agents#3", earlier, 1),
		pr("github:pr:agentloops-dev/agent-loops#4", last, 1),
		// One PR under two names: banked before the moves, and merged after.
		pr("github:pr:alexec/agents#5", earlier, 2),
		pr("github:pr:agentloops-dev/agent-loops#5", last, 3),
	} {
		nodes[costKey(c.Node)] = c
	}
	b, _ := json.Marshal(costLedgerFile{Nodes: nodes, Unsent: map[string]int64{"pr\tgithub:pr:alexec/agents#1": 1}, Refs: ledgerRefsFull})
	if err := os.WriteFile(filepath.Join(root, "lineage-cost.json"), b, 0o600); err != nil {
		t.Fatal(err)
	}
	session := wire.LineageNode{Kind: "session", Ref: "agents:session:agentloops-dev/agent-loops#11111111-2222-3333-4444-555555555555"}
	for n := 1; n <= 5; n++ {
		to := wire.LineageNode{Kind: "pr", Ref: "github:pr:agentloops-dev/agent-loops#" + strconv.Itoa(n)}
		if _, err := d.lineage().Link(wire.LineageLinkRequest{From: session, To: to, Rel: "works-on", Source: "person"}, nowFunc()); err != nil {
			t.Fatal(err)
		}
	}

	d.workMu.Lock()
	d.refreshCostLinksLocked()
	f := d.costLedgerLocked()
	merges := d.multiplierMergesLocked()
	d.workMu.Unlock()
	if len(f.Nodes) != 5 || len(merges) != 5 {
		t.Fatalf("nodes %d, merges %d, want 5 and 5: %v", len(f.Nodes), len(merges), slices.Collect(maps.Keys(f.Nodes)))
	}
	for k, c := range f.Nodes {
		if !strings.Contains(k, "agentloops-dev/agent-loops#") || len(c.Sessions) != 1 ||
			*c.Repo != "github:repo:#agentloops-dev/agent-loops" || *c.Parent != "github:issue:agentloops-dev/agent-loops#1" {
			t.Fatalf("%s: %+v", k, c)
		}
	}
	five := f.Nodes["pr\tgithub:pr:agentloops-dev/agent-loops#5"]
	if five.Banked.Cost["usd"] != 5 || *five.FirstAt != earlier || five.LastAt != last {
		t.Fatalf("the PR under two names: %+v", five)
	}
	if _, ok := f.Unsent["pr\tgithub:pr:agentloops-dev/agent-loops#1"]; !ok {
		t.Fatalf("the renamed node is not sent again: %v", f.Unsent)
	}
	for k := range f.Unsent {
		if !strings.Contains(k, "agent-loops") {
			t.Fatalf("an old key left unsent: %v", f.Unsent)
		}
	}
}

// #5332: a repo that moved twice: the check asks GitHub about the name it has now, so it
// learns the second move, and the old name follows the chain to the last.
func TestTheCheckFollowsASecondMove(t *testing.T) {
	noAliases(t)
	repoalias.Add("github", "alexec/agents", "agentloops-dev/agents", nowFunc())
	mux := http.NewServeMux()
	mux.HandleFunc("/repos/agentloops-dev/agents", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"full_name":"agentloops-dev/agent-loops"}`))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	d, err := New(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	// A daemon left running scans on its clock into a later test's AGENTS_PERSONAL_HOME (#5368).
	t.Cleanup(d.Shutdown)
	d.repoAliasAPI = srv.URL
	pr := wire.LineageNode{Kind: "pr", Ref: "github:pr:alexec/agents#12"}
	if _, err := d.lineage().Link(wire.LineageLinkRequest{From: pr, To: wire.LineageNode{Kind: "issue", Ref: "github:issue:alexec/agents#1"},
		Rel: "fixes", Source: "person"}, nowFunc()); err != nil {
		t.Fatal(err)
	}
	if n := d.checkRepoAliases(context.Background()); n != 1 {
		t.Fatalf("added %d, want 1: %+v", n, repoalias.All())
	}
	if got := repoalias.Topic("github", "alexec/agents"); got != "agentloops-dev/agent-loops" {
		t.Fatalf("alias: %q", got)
	}
	if got := d.lineage().Links(wire.LineageNode{Kind: "pr", Ref: "github:pr:agentloops-dev/agent-loops#12"}); len(got.Links) != 1 {
		t.Fatalf("the PR by its name now: %+v", got)
	}
}

// #5335: the daemon reads a folder's origin again when it changes, so Work searches the new
// name after `git remote set-url`, not the one it read at the start.
func TestAFolderRepoFollowsANewOrigin(t *testing.T) {
	d, err := New(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	// A daemon left running scans on its clock into a later test's AGENTS_PERSONAL_HOME (#5368).
	t.Cleanup(d.Shutdown)
	folder := gitFolder(t, "https://github.com/alexec/Agents.git")
	if got := d.folderRepo(folder).path; !strings.EqualFold(got, "alexec/agents") {
		t.Fatalf("before: %q", got)
	}
	if out, err := exec.Command("git", "-C", folder, "remote", "set-url", "origin", "https://github.com/agentloops-dev/agent-loops.git").CombinedOutput(); err != nil {
		t.Fatalf("set-url: %v %s", err, out)
	}
	// A file system with coarse times would show no change in the same second.
	later := time.Now().Add(2 * time.Second)
	if err := os.Chtimes(filepath.Join(folder, ".git", "config"), later, later); err != nil {
		t.Fatal(err)
	}
	if got := d.folderRepo(folder).path; !strings.EqualFold(got, "agentloops-dev/agent-loops") {
		t.Fatalf("after: %q", got)
	}
	if got := d.folderTopic(folder); !strings.EqualFold(got, "agentloops-dev/agent-loops") {
		t.Fatalf("topic after: %q", got)
	}
}

// #5335: GitHub's search answers 422 for a repo's old name, so Work searches the name now.
func TestWorkSearchesAMovedRepoByItsNameNow(t *testing.T) {
	noAliases(t)
	d, err := New(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	// A daemon left running scans on its clock into a later test's AGENTS_PERSONAL_HOME (#5368).
	t.Cleanup(d.Shutdown)
	folder := gitFolder(t, "https://github.com/alexec/Agents.git")
	repoalias.Add("github", "alexec/agents", "agentloops-dev/agents", nowFunc())
	repoalias.Add("github", "agentloops-dev/agents", "agentloops-dev/agent-loops", nowFunc())
	s := githubForge{d: d}.scopeOf([]string{folder})
	if !slices.Equal(s.repos, []string{"agentloops-dev/agent-loops"}) || s.folderOf["agentloops-dev/agent-loops"] != folder {
		t.Fatalf("scope %+v", s)
	}
}
