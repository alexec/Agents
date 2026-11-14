package lineage

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/repoalias"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

func movedPR(n string) wire.LineageNode {
	return wire.LineageNode{Kind: KindPR, Ref: "github:pr:agentloops-dev/agent-loops#" + n}
}

// #4957: a PR linked before its repo's owner moved and named by the new owner after it is
// one node, and the file is not written again for the move.
func TestARepoThatMovedIsOneNode(t *testing.T) {
	repoalias.Set(nil)
	t.Cleanup(func() { repoalias.Set(nil) })
	path := filepath.Join(t.TempDir(), "lineage.jsonl")
	f := openAt(t, path, t0)
	link(t, f, session("a"), pr("2"), RelOpens, t0)
	link(t, f, pr("2"), issue("1"), RelFixes, t0)
	_ = f.Close()
	before, _ := os.ReadFile(path)

	repoalias.Add("github", "alexec/agents", "agentloops-dev/agent-loops", t0)
	g := openAt(t, path, t0.Add(time.Minute))
	if got := g.Links(movedPR("2")); len(got.Links) != 2 {
		t.Fatalf("the new name's links: %+v", got)
	}
	if got := g.Links(pr("2")); len(got.Links) != 2 || got.Links[0].From != movedPR("2") && got.Links[0].To != movedPR("2") {
		t.Fatalf("the old name's links: %+v", got)
	}
	link(t, g, session("b"), movedPR("2"), RelReviews, t0.Add(2*time.Minute))
	if got := g.Links(pr("2")); len(got.Links) != 3 {
		t.Fatalf("after a link by the new name: %+v", got)
	}
	after, _ := os.ReadFile(path)
	if !strings.HasPrefix(string(after), string(before)) {
		t.Fatal("the file was written again for the move")
	}
}

// An alias learnt while the store is open names its nodes again, and the same active link by
// both names is one.
func TestRealiasWhileOpen(t *testing.T) {
	repoalias.Set(nil)
	t.Cleanup(func() { repoalias.Set(nil) })
	f := openAt(t, filepath.Join(t.TempDir(), "lineage.jsonl"), t0)
	link(t, f, session("a"), pr("2"), RelOpens, t0)
	link(t, f, session("a"), movedPR("2"), RelOpens, t0.Add(time.Minute))
	if got := f.Links(pr("2")); len(got.Links) != 1 {
		t.Fatalf("before the alias: %+v", got)
	}
	repoalias.Add("github", "alexec/agents", "agentloops-dev/agent-loops", t0)
	f.Realias()
	if got := f.Links(pr("2")); len(got.Links) != 1 || got.Links[0].To != movedPR("2") {
		t.Fatalf("after the alias: %+v", got)
	}
	if g := f.Walk(movedPR("2"), 0); len(g.Nodes) != 2 {
		t.Fatalf("walk: %+v", g.Nodes)
	}
}
