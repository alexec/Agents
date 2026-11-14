package agentsd

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/agentloops-dev/agents/Go/internal/repoalias"
	"github.com/agentloops-dev/agents/Go/wire"
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
	newPR := wire.Ref{Provider: "github", Type: "pr", Topic: "agentloops-dev/agents", ID: "4702"}
	provider, topic := "github", "agentloops-dev/Agents"
	e := wire.Event{Name: "pr.merged", Provider: &provider, Topic: &topic, Subject: &newPR,
		Details: map[string]string{"repo": "agentloops-dev/Agents", "pr": "4702"}}
	byOld := waitPattern{name: "pr.merged", filters: map[string][]string{"repo": {"alexec/Agents"}, "pr": {"4702"}},
		bus: busFilter{topics: []string{"alexec/agents"}, subject: &oldPR}}
	if byOld.matches(e) {
		t.Fatal("matched by the old name before the alias")
	}
	repoalias.Add("github", "alexec/Agents", "agentloops-dev/Agents", nowFunc())
	if !byOld.matches(e) {
		t.Fatal("the old name does not hear the new one's event")
	}
	old := wire.Event{Name: "pr.merged", Provider: &provider, Subject: &oldPR, Details: map[string]string{"repo": "alexec/Agents", "pr": "4702"}}
	byNew := waitPattern{name: "pr.merged", filters: map[string][]string{"repo": {"agentloops-dev/Agents"}}, bus: busFilter{subject: &newPR}}
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
		_, _ = w.Write([]byte(`{"full_name":"agentloops-dev/Agents"}`))
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
	if got := repoalias.Topic("github", "alexec/agents"); got != "agentloops-dev/agents" {
		t.Fatalf("alias: %q", got)
	}
	if _, err := os.Stat(d.repoAliasesPath()); err != nil {
		t.Fatal(err)
	}
	if got := d.lineage().Links(wire.LineageNode{Kind: "pr", Ref: "github:pr:agentloops-dev/agents#12"}); len(got.Links) != 2 {
		t.Fatalf("the PR by its new name: %+v", got)
	}
	if n := d.checkRepoAliases(context.Background()); n != 0 {
		t.Fatalf("the second check added %d", n)
	}
}
