package lineage

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

var t0 = time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)

func issue(n string) wire.LineageNode {
	return wire.LineageNode{Kind: KindIssue, Ref: "github:alexec/Agents#" + n}
}
func pr(n string) wire.LineageNode { return wire.LineageNode{Kind: KindPR, Ref: "github:alexec/Agents#" + n} }
func session(id string) wire.LineageNode {
	return wire.LineageNode{Kind: KindSession, Ref: "session:" + id}
}

func link(t *testing.T, s Store, from, to wire.LineageNode, rel string, at time.Time) wire.LineageLink {
	t.Helper()
	l, err := s.Link(wire.LineageLinkRequest{From: from, To: to, Rel: rel, Source: SourcePerson}, at)
	if err != nil {
		t.Fatal(err)
	}
	return l
}

func openAt(t *testing.T, path string, now time.Time) *Files {
	t.Helper()
	f := Open(path, func() time.Time { return now })
	t.Cleanup(func() { f.Close() })
	return f
}

// Many sessions work on one issue, one session opens many PRs, and the walk from the issue
// finds the sessions and their PRs (issue → sessions → PRs).
func TestManyToManyAndTheWalk(t *testing.T) {
	path := filepath.Join(t.TempDir(), "lineage.jsonl")
	f := openAt(t, path, t0)
	link(t, f, session("a"), issue("1"), RelWorksOn, t0)
	link(t, f, session("b"), issue("1"), RelWorksOn, t0.Add(time.Minute))
	link(t, f, session("a"), pr("2"), RelOpens, t0.Add(2*time.Minute))
	link(t, f, session("a"), pr("3"), RelOpens, t0.Add(3*time.Minute))
	link(t, f, session("b"), pr("3"), RelReviews, t0.Add(4*time.Minute))
	link(t, f, pr("4"), issue("9"), RelFixes, t0.Add(5*time.Minute)) // elsewhere

	got := f.Links(issue("1"))
	if len(got.Links) != 2 || got.Links[0].From != session("b") || got.Limited != nil {
		t.Fatalf("issue 1's links, newest first: %+v", got)
	}
	g := f.Walk(issue("1"), 0)
	if len(g.Nodes) != 5 || len(g.Links) != 5 || g.Nodes[0] != issue("1") {
		t.Fatalf("walk: %d nodes %+v, %d links", len(g.Nodes), g.Nodes, len(g.Links))
	}
	for _, n := range g.Nodes {
		if n == pr("4") || n == issue("9") {
			t.Fatal("the walk reached a part of the graph not linked to the issue")
		}
	}
	if one := f.Walk(issue("1"), 1); len(one.Nodes) != 3 {
		t.Fatalf("depth 1: %+v", one.Nodes)
	}
}

// The same active link again is the one there; an ended link can start again, as a new one.
func TestLinkAgainAndEnd(t *testing.T) {
	path := filepath.Join(t.TempDir(), "lineage.jsonl")
	f := openAt(t, path, t0)
	first := link(t, f, session("a"), issue("1"), RelWorksOn, t0)
	if again := link(t, f, session("a"), issue("1"), RelWorksOn, t0.Add(time.Hour)); again != first {
		t.Fatalf("again: %+v", again)
	}
	end := wire.LineageEndRequest{From: session("a"), To: issue("1"), Rel: RelWorksOn}
	ended, err := f.End(end, t0.Add(2*time.Hour))
	if err != nil || len(ended) != 1 || ended[0].EndedAt == nil || ended[0].EndedAt.Time() != t0.Add(2*time.Hour) {
		t.Fatalf("end: %+v %v", ended, err)
	}
	if none, _ := f.End(end, t0.Add(3*time.Hour)); len(none) != 0 {
		t.Fatalf("ended twice: %+v", none)
	}
	link(t, f, session("a"), issue("1"), RelWorksOn, t0.Add(4*time.Hour))
	if got := f.Links(issue("1")).Links; len(got) != 2 || got[0].EndedAt != nil || got[1].EndedAt == nil {
		t.Fatalf("%+v", got)
	}
}

// What is written is read again, ended links too, also after the file is written whole.
func TestReadAgain(t *testing.T) {
	path := filepath.Join(t.TempDir(), "lineage.jsonl")
	f := openAt(t, path, t0)
	link(t, f, session("a"), issue("1"), RelWorksOn, t0)
	link(t, f, session("a"), pr("2"), RelOpens, t0.Add(time.Minute))
	f.End(wire.LineageEndRequest{From: session("a"), To: issue("1"), Rel: RelWorksOn}, t0.Add(time.Hour))
	want := f.Walk(session("a"), 1)
	f.Close()

	again := openAt(t, path, t0.Add(2*time.Hour))
	if got := again.Walk(session("a"), 1); len(got.Links) != 2 || got.Links[1].EndedAt == nil || len(got.Nodes) != len(want.Nodes) {
		t.Fatalf("read again: %+v", got)
	}
	again.mu.Lock()
	again.prune()
	again.rewrite()
	again.mu.Unlock()
	again.Close()
	whole := openAt(t, path, t0.Add(2*time.Hour))
	got := whole.Links(issue("1")).Links
	if len(got) != 1 || got[0].EndedAt == nil || got[0].EndedAt.Time() != t0.Add(time.Hour) {
		t.Fatalf("after a rewrite: %+v", got)
	}
	// Ended, so it can start again.
	if l := link(t, whole, session("a"), issue("1"), RelWorksOn, t0.Add(3*time.Hour)); l.EndedAt != nil {
		t.Fatal(l)
	}
}

// A torn last line is dropped; a line in the middle that cannot be read is left out and the
// file is set aside, and what is kept is written again.
func TestTornAndUnreadableLines(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "lineage.jsonl")
	f := openAt(t, path, t0)
	link(t, f, session("a"), issue("1"), RelWorksOn, t0)
	f.Close()
	b, _ := os.ReadFile(path)
	os.WriteFile(path, append(b, []byte(`{"link":{"from"`)...), 0o644)
	torn := openAt(t, path, t0)
	if n := len(torn.Links(issue("1")).Links); n != 1 {
		t.Fatalf("torn: %d", n)
	}
	// The next line starts on a line of its own.
	link(t, torn, session("b"), issue("1"), RelWorksOn, t0.Add(time.Minute))
	torn.Close()
	if n := len(openAt(t, path, t0).Links(issue("1")).Links); n != 2 {
		t.Fatalf("after the torn line: %d", n)
	}

	b, _ = os.ReadFile(path)
	os.WriteFile(path, append([]byte("not json\n"), b...), 0o644)
	bad := openAt(t, path, t0)
	if n := len(bad.Links(issue("1")).Links); n != 2 {
		t.Fatalf("unreadable: %d", n)
	}
	matches, _ := filepath.Glob(path + ".unreadable-*")
	if len(matches) != 1 {
		t.Fatalf("set aside: %v", matches)
	}
	if b, _ := os.ReadFile(path); strings.Contains(string(b), "not json") {
		t.Fatal("the unreadable line is still in the file")
	}
}

// An ended link goes KeepEnded after its end; an active one stays, however old.
func TestEndedLinksGoAfterKeepEnded(t *testing.T) {
	path := filepath.Join(t.TempDir(), "lineage.jsonl")
	f := openAt(t, path, t0)
	link(t, f, session("a"), issue("1"), RelWorksOn, t0)
	link(t, f, session("b"), issue("1"), RelWorksOn, t0)
	f.End(wire.LineageEndRequest{From: session("a"), To: issue("1"), Rel: RelWorksOn}, t0)
	f.Close()
	later := openAt(t, path, t0.Add(KeepEnded+time.Hour))
	got := later.Links(issue("1")).Links
	if len(got) != 1 || got[0].From != session("b") {
		t.Fatalf("%+v", got)
	}
}

// At most MostLinks are kept, the oldest ended ones first; the file does not grow past what
// is kept by more than the margin.
func TestTheStoreIsBounded(t *testing.T) {
	path := filepath.Join(t.TempDir(), "lineage.jsonl")
	f := openAt(t, path, t0)
	ended := wire.LineageEndRequest{From: session("old"), To: issue("1"), Rel: RelWorksOn}
	link(t, f, ended.From, ended.To, ended.Rel, t0)
	f.End(ended, t0)
	for i := range MostLinks + rewriteMargin {
		link(t, f, session(fmt.Sprint(i)), pr("2"), RelOpens, t0)
	}
	f.mu.Lock()
	n, lines := len(f.links), f.appended
	f.mu.Unlock()
	if n > MostLinks+rewriteMargin/2 || lines > n+rewriteMargin {
		t.Fatalf("%d links, %d lines", n, lines)
	}
	if len(f.Links(issue("1")).Links) != 0 {
		t.Fatal("the ended link was kept over active ones")
	}
	if got := f.Links(pr("2")); len(got.Links) != MostAnswer || got.Limited == nil {
		t.Fatalf("an answer holds %d", len(got.Links))
	}
	g := f.Walk(pr("2"), 1)
	if len(g.Nodes) != MostNodes || g.Limited == nil {
		t.Fatalf("a walk reached %d", len(g.Nodes))
	}
}

func TestRefusesWhatIsNotANodeOrALink(t *testing.T) {
	f := openAt(t, filepath.Join(t.TempDir(), "lineage.jsonl"), t0)
	for _, r := range []wire.LineageLinkRequest{
		{From: wire.LineageNode{Kind: "Issue", Ref: "github:a#1"}, To: issue("1"), Rel: RelFixes, Source: SourceAgent},
		{From: wire.LineageNode{Kind: KindPR, Ref: "#1"}, To: issue("1"), Rel: RelFixes, Source: SourceAgent},
		{From: pr("1"), To: issue("1"), Rel: "", Source: SourceAgent},
		{From: pr("1"), To: issue("1"), Rel: RelFixes, Source: "by hand"},
		{From: pr("1"), To: wire.LineageNode{Kind: KindIssue, Ref: "github:" + strings.Repeat("x", maxRef)}, Rel: RelFixes, Source: SourceAgent},
	} {
		if _, err := f.Link(r, t0); err == nil {
			t.Errorf("took %+v", r)
		}
	}
	// A kind, relationship or source this build does not name is kept.
	if _, err := f.Link(wire.LineageLinkRequest{From: wire.LineageNode{Kind: "deploy", Ref: "argo:prod/42"}, To: pr("1"), Rel: "ships", Source: "webhook"}, t0); err != nil {
		t.Fatal(err)
	}
}
