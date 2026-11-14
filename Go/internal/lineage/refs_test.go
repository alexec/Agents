package lineage

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/wire"
)

// #4800: a file written before the full ref form reads in it, and is written again in it; a
// session named with its project and without one is one node.
func TestOpenReadsTheOldFormAsFullRefs(t *testing.T) {
	path := filepath.Join(t.TempDir(), "lineage.jsonl")
	old := `{"link":{"from":{"kind":"session","ref":"session:A1"},"to":{"kind":"issue","ref":"github:alexec/Agents#12"},"rel":"works-on","source":"start","at":AT1}}
{"link":{"from":{"kind":"pr","ref":"gitlab:group/repo!4"},"to":{"kind":"issue","ref":"linear:ENG-4"},"rel":"fixes","source":"pr-body","at":AT2}}
{"link":{"from":{"kind":"ci-run","ref":"github:alexec/agents/actions/run/9"},"to":{"kind":"release","ref":"github:alexec/agents/release/v1.0.0"},"rel":"builds","source":"forge","at":AT3}}
{"end":{"from":{"kind":"session","ref":"session:A1"},"to":{"kind":"issue","ref":"github:alexec/agents#12"},"rel":"works-on"},"at":AT4}
{"state":{"node":{"kind":"session","ref":"session:A1"},"state":"working"},"at":AT5}
`
	for i := 1; i <= 5; i++ {
		old = strings.ReplaceAll(old, "AT"+strconv.Itoa(i), strconv.FormatFloat(float64(wire.DateOf(t0))+float64(i), 'f', -1, 64))
	}
	if err := os.WriteFile(path, []byte(old), 0o644); err != nil {
		t.Fatal(err)
	}
	topics := func(kind, id string) string {
		if kind == KindSession && id == "A1" {
			return "Alexec/Agents"
		}
		return ""
	}
	f := OpenWith(path, func() time.Time { return t0 }, topics)
	s := wire.LineageNode{Kind: KindSession, Ref: "agents:session:alexec/agents#A1"}
	got := f.Links(s)
	if len(got.Links) != 1 || got.Links[0].To.Ref != "github:issue:alexec/agents#12" || got.Links[0].EndedAt == nil ||
		len(got.States) != 1 {
		t.Fatalf("the session's links: %+v", got)
	}
	// Asked in the old form, or with no project, it is the same node.
	for _, ask := range []wire.LineageNode{{Kind: KindSession, Ref: "session:A1"}, {Kind: KindSession, Ref: "agents:session:#A1"}} {
		if f.Canon(ask) != s || len(f.Links(ask).Links) != 1 {
			t.Errorf("%v is not %v", ask, s)
		}
	}
	if l := f.Links(wire.LineageNode{Kind: KindIssue, Ref: "linear:issue:eng#ENG-4"}).Links; len(l) != 1 || l[0].From.Ref != "gitlab:mr:group/repo#4" {
		t.Errorf("the Linear issue's links: %+v", l)
	}
	if l := f.Links(wire.LineageNode{Kind: KindRelease, Ref: "github:release:alexec/agents#v1.0.0"}).Links; len(l) != 1 ||
		l[0].From.Ref != "github:run:alexec/agents#9" {
		t.Errorf("the release's links: %+v", l)
	}
	// A link made now with no project goes on the same session.
	if l, err := f.Link(wire.LineageLinkRequest{From: wire.LineageNode{Kind: KindSession, Ref: "agents:session:#A1"},
		To: wire.LineageNode{Kind: KindPR, Ref: "github:pr:alexec/agents#13"}, Rel: RelOpens, Source: SourceBranch}, t0); err != nil || l.From != s {
		t.Fatalf("%+v, %v", l, err)
	}
	f.Close()
	data, _ := os.ReadFile(path)
	if strings.Contains(string(data), `"session:A1"`) || strings.Contains(string(data), "/release/") {
		t.Fatalf("the file is not in the full form:\n%s", data)
	}
	again := Open(path, func() time.Time { return t0 })
	defer again.Close()
	if got := again.Links(s); len(got.Links) != 2 || len(got.States) != 1 {
		t.Fatalf("read again: %+v", got)
	}
}

func TestFullCostNode(t *testing.T) {
	repo, parent := "github:alexec/agents", "github:alexec/agents#1"
	c := FullCostNode(wire.LineageCostNode{Node: wire.LineageNode{Kind: KindPR, Ref: "github:alexec/agents#7"}, Repo: &repo,
		Parent: &parent, Fixes: []string{"github:alexec/agents#2"}, PartOf: []string{"github:alexec/agents/release/v1.0.0"},
		Sessions: []string{"session:A1"}}, func(kind, id string) string { return "alexec/agents" })
	if c.Node.Ref != "github:pr:alexec/agents#7" || *c.Repo != "github:repo:#alexec/agents" || *c.Parent != "github:issue:alexec/agents#1" ||
		c.Fixes[0] != "github:issue:alexec/agents#2" || c.PartOf[0] != "github:release:alexec/agents#v1.0.0" ||
		c.Sessions[0] != "agents:session:alexec/agents#A1" {
		t.Fatalf("%+v", c)
	}
	if repo != "github:alexec/agents" {
		t.Fatal("the node given was changed")
	}
	if got := FullRepoText("folder:scratch"); got != "folder:repo:#scratch" {
		t.Errorf("%q", got)
	}
	if !SameRepo("github:alexec/Agents", "github:repo:#alexec/agents") || SameRepo("github:o/r", "gitlab:o/r") {
		t.Error("SameRepo")
	}
	if id, ok := SessionID("agents:session:alexec/agents#A1"); !ok || id != "A1" {
		t.Errorf("%q %v", id, ok)
	}
	if id, ok := SessionID("session:A1"); !ok || id != "A1" {
		t.Errorf("old form: %q %v", id, ok)
	}
}

func TestNamesKeepsOneSession(t *testing.T) {
	var m Names
	a := m.Name(wire.LineageNode{Kind: KindSession, Ref: "agents:session:alexec/agents#A1"})
	if b := m.Name(wire.LineageNode{Kind: KindSession, Ref: "session:A1"}); b != a {
		t.Fatalf("%v, %v", a, b)
	}
	if c := m.Ask(wire.LineageNode{Kind: KindSession, Ref: "agents:session:#A1"}); c != a {
		t.Fatalf("%v", c)
	}
	if d := m.Ask(wire.LineageNode{Kind: KindSession, Ref: "session:B2"}); d.Ref != "agents:session:#B2" {
		t.Fatalf("%v", d)
	}
}
