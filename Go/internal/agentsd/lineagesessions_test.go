package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// #3899: a search for #<n> names the issue, issue:#<n> and issue:<n> too, as a word of its own.
func TestIssueNumberIn(t *testing.T) {
	for query, want := range map[string]int{
		"#3465": 3465, "issue:#3465": 3465, "issue:12 flaky": 12, "flaky #7": 7, "ISSUE:#8": 8,
		"P#3465": 0, "a#1": 0, "#12a": 0, "label:#3465": 0, "flaky": 0, "#": 0,
	} {
		if got := issueNumberIn(query); got != want {
			t.Errorf("issueNumberIn(%q) = %d, want %d", query, got, want)
		}
	}
}

func TestNamesIssue(t *testing.T) {
	for text, want := range map[string]bool{
		"#3899: Session search": false, "Fix #38 now": true, "#3899 and #38": true, "#3899": false, "end #38": true,
	} {
		if got := namesIssue(text, "#38"); got != want {
			t.Errorf("namesIssue(%q) = %v, want %v", text, got, want)
		}
	}
}

// #3899: lineage/sessions is the sessions on the epic, on its sub-issues and on their PRs, each
// once and on the issue it came by, and not a session on another issue that a lane also touched.
func TestLineageSessionsOnAnEpic(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := realTempDir(t)
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	c.call(t, 9, "folders/add", map[string]any{"folder": "file://" + folder})
	repo := d.repos[folder]
	epic, child, other := repo.issue(3465), repo.issue(3466), repo.issue(9)
	pr := repo.pr(40)
	s := func(n string) wire.LineageNode {
		return sessionNode(wire.UUID("00000000-0000-0000-0000-00000000000" + n))
	}
	d.lineageDo(func() {
		d.link(s("1"), epic, lineage.RelWorksOn, lineage.SourceStart)
		d.link(child, epic, lineage.RelPartOf, lineage.SourceForge)
		d.link(s("2"), child, lineage.RelWorksOn, lineage.SourceStart)
		d.link(s("2"), other, lineage.RelWorksOn, lineage.SourceStart)
		d.link(pr, child, lineage.RelFixes, lineage.SourcePRBody)
		d.link(s("3"), pr, lineage.RelOpens, lineage.SourceBranch)
		d.link(s("4"), other, lineage.RelWorksOn, lineage.SourceStart)
	})
	d.lineageSettle(2 * time.Second)
	var got wire.LineageSessions
	json.Unmarshal(c.call(t, 1, "lineage/sessions", wire.LineageSessionsRequest{Number: 3465}), &got)
	want := map[string]string{"1": epic.Ref, "2": child.Ref, "3": child.Ref}
	if len(got.Matches) != len(want) || got.Limited != nil {
		t.Fatalf("%+v", got)
	}
	for _, m := range got.Matches {
		n := string(m.AgentID)[len(m.AgentID)-1:]
		if want[n] != m.On.Ref {
			t.Errorf("session %s on %s, want %s", n, m.On.Ref, want[n])
		}
	}
	json.Unmarshal(c.call(t, 2, "lineage/sessions", wire.LineageSessionsRequest{Number: 1}), &got)
	if len(got.Matches) != 0 {
		t.Fatalf("an issue lineage does not know: %+v", got)
	}
}

// #3899: agents/list's #<n> query sends the sessions on the issue, archived ones too, those
// labelled #<n> and those with #<n> in their title, and leaves the rest to the client.
func TestListQueryForAnIssue(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := realTempDir(t)
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})
	titled, longer := "#3465: an epic", "#34650: another"
	byUser := wire.AgentArchivedReasonByUser
	on := seeded(t, d, folder, func(a *wire.Agent) { a.State, a.ArchivedReason = wire.AgentStateArchived, &byUser }).ID
	labelled := seeded(t, d, folder, func(a *wire.Agent) { a.Labels = []wire.SessionLabel{{Value: "#3465"}} }).ID
	named := seeded(t, d, folder, func(a *wire.Agent) { a.Title = &titled }).ID
	seeded(t, d, folder, func(a *wire.Agent) { a.Title = &longer })
	seeded(t, d, folder, nil)
	d.lineageDo(func() { d.link(sessionNode(on), d.repos[folder].issue(3465), lineage.RelWorksOn, lineage.SourceStart) })
	d.lineageSettle(2 * time.Second)
	var listed []wire.Agent
	json.Unmarshal(c.call(t, 2, "agents/list", map[string]any{"includeArchived": true, "query": "#3465 words"}), &listed)
	got := map[wire.UUID]bool{}
	for _, a := range listed {
		got[a.ID] = true
	}
	if len(listed) != 3 || !got[on] || !got[labelled] || !got[named] {
		t.Fatalf("listed %+v", listed)
	}
}

// #3900: lineage/sessions says the epic, then its sub-issues in the forge's order (by number for
// those it has not said), with the titles it has; a session on two of them is on the first.
func TestLineageSessionsIssuesInTheEpicsOrder(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := realTempDir(t)
	d.repos = map[string]forgeRepo{folder: {"github", "alexec/agents"}}
	c.call(t, 9, "folders/add", map[string]any{"folder": "file://" + folder})
	repo := d.repos[folder]
	epic, first, second, unsaid := repo.issue(3897), repo.issue(3900), repo.issue(3898), repo.issue(3899)
	d.resolveMu.Lock()
	d.resolveLookup = func(context.Context, string, forgeRepo, string, int) (wire.LineageResolved, error) {
		return wire.LineageResolved{}, errors.New("not asked in this test")
	}
	d.resolveCache = map[wire.LineageNode]resolvedEntry{epic: {resolved: wire.LineageResolved{Title: "Find sessions"}, ok: true, at: nowFunc()}}
	d.resolveMu.Unlock()
	d.issueMu.Lock()
	d.subIssues = map[wire.LineageNode][]wire.LineageNode{epic: {first, second}}
	d.issueMu.Unlock()
	both := sessionNode("00000000-0000-0000-0000-000000000001")
	d.lineageDo(func() {
		for _, child := range []wire.LineageNode{unsaid, second, first} {
			d.link(child, epic, lineage.RelPartOf, lineage.SourceForge)
		}
		d.link(both, second, lineage.RelWorksOn, lineage.SourceStart)
		d.link(both, first, lineage.RelWorksOn, lineage.SourceStart)
	})
	d.lineageSettle(2 * time.Second)
	var got wire.LineageSessions
	json.Unmarshal(c.call(t, 1, "lineage/sessions", wire.LineageSessionsRequest{Number: 3897}), &got)
	var order []string
	for _, i := range got.Issues {
		order = append(order, i.Node.Ref)
	}
	if want := []string{epic.Ref, first.Ref, second.Ref, unsaid.Ref}; !slices.Equal(order, want) {
		t.Fatalf("issues %v, want %v", order, want)
	}
	if got.Issues[0].Title == nil || *got.Issues[0].Title != "Find sessions" || got.Issues[1].Title != nil {
		t.Errorf("titles %+v", got.Issues)
	}
	if len(got.Matches) != 1 || got.Matches[0].On != first {
		t.Errorf("matches %+v, want the session on %s", got.Matches, first.Ref)
	}
}
