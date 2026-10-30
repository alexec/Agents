package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// #2352: the setting is the folder's .agents/folder.json; off is no key.
func TestAFoldersPRCostCommentIsItsFile(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	folder := store.FolderURL(dir)
	if e := c.callError(t, 2, "folders/setPRCostComment", map[string]any{"folder": folder, "prCostComment": "all"}); !strings.HasPrefix(e.Message, "The cost on pull requests is off, tokens or cost") {
		t.Fatal(e.Message)
	}
	var s wire.FolderSummary
	json.Unmarshal(c.call(t, 3, "folders/setPRCostComment", map[string]any{"folder": folder, "prCostComment": "cost"}), &s)
	if s.Folder.PrCostComment == nil || *s.Folder.PrCostComment != wire.PRCostCommentCost || d.prCostCommentOf(dir) != wire.PRCostCommentCost {
		t.Fatalf("%+v", s.Folder.PrCostComment)
	}
	b, _ := os.ReadFile(filepath.Join(dir, ".agents", "folder.json"))
	if !strings.Contains(string(b), `"prCostComment" : "cost"`) {
		t.Fatalf("%s", b)
	}
	s = wire.FolderSummary{}
	json.Unmarshal(c.call(t, 4, "folders/setPRCostComment", map[string]any{"folder": folder, "prCostComment": "off"}), &s)
	b, _ = os.ReadFile(filepath.Join(dir, ".agents", "folder.json"))
	if s.Folder.PrCostComment != nil || strings.Contains(string(b), "prCostComment") {
		t.Fatalf("%+v %s", s.Folder.PrCostComment, b)
	}
}

type fakeCommenter struct {
	mu    sync.Mutex
	posts []string
	ids   []string
}

func (f *fakeCommenter) comment(_ context.Context, r prCommentRecord, body string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.posts = append(f.posts, body)
	f.ids = append(f.ids, r.ID)
	return "77", nil
}

// #2352: a merge posts one comment with the PR's cost and its issue's; more cost later
// edits that comment; tokens only says no cost; off says nothing.
func TestAMergedPRSaysWhatItCost(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	fake := &fakeCommenter{}
	was, wasAfter := prCommenter, prCommentAfter
	prCommenter, prCommentAfter = fake.comment, time.Hour
	defer func() { prCommenter, prCommentAfter = was, wasAfter }()

	dir := folder(t, c, 1)
	d.repos = map[string]forgeRepo{dir: {"github", "alexec/agents"}}
	c.call(t, 2, "folders/setPRCostComment", map[string]any{"folder": store.FolderURL(dir), "prCostComment": "cost"})
	branch := "agents/7-fix"
	a := seeded(t, d, dir, func(a *wire.Agent) {
		a.Worktree = &wire.AgentWorktree{Name: "7-fix", Branch: &branch, Folder: store.FolderURL(dir)}
		a.Labels = []wire.SessionLabel{{Value: "#7", Owner: wire.SessionLabelOwnerPerson}}
	})
	d.noteLineage(nil, a)
	d.bankSessionCost(a.ID, wire.Cost{Amount: 1, Currency: "USD"})
	event := func(name string) wire.Event {
		return wire.Event{Name: name, Details: map[string]string{"payload": `{"pr":{"number":10,"branch":"agents/7-fix",` +
			`"title":"Fix it","url":"https://github.com/alexec/Agents/pull/10","fixes":["#7"]}}`}}
	}
	d.lineageEvent(event("pr.opened"))
	// Up 2: half on the issue, half on the PR.
	d.bankSessionCost(a.ID, wire.Cost{Amount: 3, Currency: "USD"})
	d.bankTurnUsage(a.ID, wire.TurnUsage{TotalTokens: 12_500, InputTokens: 12_000, OutputTokens: 500})
	d.lineageEvent(event("checks.failed"))
	d.lineageEvent(event("pr.merged"))
	d.lineageSettle(2 * time.Second)
	d.flushPRComments()

	if len(fake.posts) != 1 || fake.ids[0] != "" {
		t.Fatalf("%q", fake.posts)
	}
	body := fake.posts[0]
	for _, want := range []string{prCommentMark, "| Cost | $3.00 |", "| Tokens | 12.0k in, 500 out |", "| Sessions | 1 |",
		"| Failed CI rounds | 1 |", "With the work on #7."} {
		if !strings.Contains(body, want) {
			t.Fatalf("no %q in\n%s", want, body)
		}
	}

	// Nothing new: no edit.
	d.flushPRComments()
	if len(fake.posts) != 1 {
		t.Fatalf("%d posts", len(fake.posts))
	}
	// More cost on the issue after the merge edits the same comment.
	d.bankSessionCost(a.ID, wire.Cost{Amount: 4, Currency: "USD"})
	d.lineageSettle(2 * time.Second)
	d.flushPRComments()
	if len(fake.posts) != 2 || fake.ids[1] != "77" || !strings.Contains(fake.posts[1], "| Cost | $4.00 |") {
		t.Fatalf("%q %q", fake.posts, fake.ids)
	}
	// Tokens only: no cost.
	c.call(t, 3, "folders/setPRCostComment", map[string]any{"folder": store.FolderURL(dir), "prCostComment": "tokens"})
	d.bankSessionCost(a.ID, wire.Cost{Amount: 5, Currency: "USD"})
	d.lineageSettle(2 * time.Second)
	d.flushPRComments()
	if len(fake.posts) != 3 || strings.Contains(fake.posts[2], "| Cost |") {
		t.Fatalf("%q", fake.posts)
	}
	// Off: nothing more.
	c.call(t, 4, "folders/setPRCostComment", map[string]any{"folder": store.FolderURL(dir), "prCostComment": "off"})
	d.bankSessionCost(a.ID, wire.Cost{Amount: 6, Currency: "USD"})
	d.lineageSettle(2 * time.Second)
	d.flushPRComments()
	if len(fake.posts) != 3 {
		t.Fatalf("%q", fake.posts)
	}
}

// #2352: a folder with the setting off says nothing on a merge.
func TestAMergeSaysNothingWhenOff(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	fake := &fakeCommenter{}
	was := prCommenter
	prCommenter = fake.comment
	defer func() { prCommenter = was }()
	dir := folder(t, c, 1)
	d.repos = map[string]forgeRepo{dir: {"github", "alexec/agents"}}
	d.lineageEvent(wire.Event{Name: "pr.merged", Details: map[string]string{"payload": `{"pr":{"url":"https://github.com/alexec/Agents/pull/3"}}`}})
	d.lineageSettle(2 * time.Second)
	d.flushPRComments()
	if len(fake.posts) != 0 {
		t.Fatalf("%q", fake.posts)
	}
}

func TestCostCommentWords(t *testing.T) {
	for _, c := range []struct{ got, want string }{
		{tokenWords(950), "950"}, {tokenWords(1_260_000), "1.3M"},
		{durationWords(45), "45s"}, {durationWords(725), "12m"}, {durationWords(3900), "1h 5m"},
		{amountsWords(map[string]float64{"USD": 1.5, "EUR": 2}), "2.00 EUR + $1.50"},
		{shortRef("github:alexec/agents#7", "github:alexec/agents#10"), "#7"},
		{shortRef("github:alexec/other#7", "github:alexec/agents#10"), "alexec/other#7"},
	} {
		if c.got != c.want {
			t.Errorf("%q, not %q", c.got, c.want)
		}
	}
}
