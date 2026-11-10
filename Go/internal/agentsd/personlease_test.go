package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The person's booking (#4268): person:<name>, its line in `by` order, and its holder's
// asks timely.

func TestLeaseByReadsMinutesAndTimes(t *testing.T) {
	at := time.Date(2026, 11, 9, 14, 0, 0, 0, time.Local)
	for _, tc := range []struct {
		raw  string
		want time.Time
	}{
		{`5`, at.Add(5 * time.Minute)},
		{`"5"`, at.Add(5 * time.Minute)},
		{`"14:30"`, at.Add(30 * time.Minute)},
		{`"2026-11-09T22:10:00Z"`, time.Date(2026, 11, 9, 22, 10, 0, 0, time.UTC)},
	} {
		got := leaseBy(json.RawMessage(tc.raw), at)
		if got == nil || !got.Time().Equal(tc.want) {
			t.Fatalf("%s: %v, want %v", tc.raw, got, tc.want)
		}
	}
	for _, raw := range []string{``, `0`, `"soon"`, `true`} {
		if got := leaseBy(json.RawMessage(raw), at); got != nil {
			t.Fatalf("%q: %v", raw, *got)
		}
	}
}

func TestTheLineIsInByOrder(t *testing.T) {
	at := time.Date(2026, 11, 9, 14, 0, 0, 0, time.UTC)
	when := func(m int) *wire.Date { d := wire.DateOf(at.Add(time.Duration(m) * time.Minute)); return &d }
	e := &leaseEntry{}
	w := func(id string, asked int, by *wire.Date) waiter {
		return waiter{AgentID: wire.UUID(id), AskedAt: wire.DateOf(at.Add(time.Duration(asked) * time.Second)), By: by}
	}
	places := []int{
		joinLine(e, w("none-1", 1, nil)),
		joinLine(e, w("by-10", 2, when(10))),
		joinLine(e, w("by-5", 3, when(5))),
		joinLine(e, w("none-2", 4, nil)),
		joinLine(e, w("by-5-later", 5, when(5))),
	}
	var got []string
	for _, l := range e.Line {
		got = append(got, string(l.AgentID))
	}
	if strings.Join(got, " ") != "by-5 by-5-later by-10 none-1 none-2" || places[2] != 1 || places[3] != 4 || places[4] != 2 {
		t.Fatalf("%v %v", got, places)
	}
}

func TestAnAgentBooksThePerson(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	os.MkdirAll(d.SettingsDir, 0o755)
	os.WriteFile(filepath.Join(d.SettingsDir, "person.json"), []byte(`{"name":"Sam"}`), 0o644)
	dir := t.TempDir()
	holder := seeded(t, d, dir, nil)
	first, later, sooner := appClient(t, d, holder.ID), appClient(t, d, seeded(t, d, dir, nil).ID), appClient(t, d, seeded(t, d, dir, nil).ID)
	for _, m := range []*mcpClient{first, later, sooner} {
		m.post("initialize", map[string]any{}, 1)
	}

	var snap wire.LeaseSnapshot
	json.Unmarshal(c.call(t, 1, "resources/snapshot", nil), &snap)
	found := false
	for _, r := range snap.Resources {
		found = found || r.Name == "person:sam" && r.DisplayName == "Sam (the person)" && r.Kind == "named"
	}
	if !found {
		t.Fatalf("no booking row: %+v", snap.Resources)
	}
	if d.holdsPerson(holder.ID) {
		t.Fatal("held before it was booked")
	}
	if text, _ := first.tool(2, "lease_resource", map[string]any{"name": "person", "minutes": 3}); !strings.HasPrefix(text, "You hold Sam (the person) until ") {
		t.Fatal(text)
	}
	if !d.holdsPerson(holder.ID) {
		t.Fatal("the holder's asks are not timely")
	}
	if text, _ := later.tool(2, "lease_resource", map[string]any{"name": "person:sam", "wait": true}); !strings.Contains(text, "You are 1st in line") {
		t.Fatal(text)
	}
	// A code that runs out in five minutes goes ahead of a step with no deadline.
	if text, _ := sooner.tool(2, "lease_resource", map[string]any{"name": "Person:Sam", "by": "5"}); !strings.Contains(text, "You are 1st in line") {
		t.Fatal(text)
	}
	if text, _ := first.tool(3, "release_resource", map[string]any{"name": "person"}); !strings.HasPrefix(text, "Released Sam (the person).") {
		t.Fatal(text)
	}
	if d.holdsPerson(holder.ID) {
		t.Fatal("still timely after release")
	}
	if e := c.callError(t, 3, "resources/declare", map[string]any{"resource": map[string]any{"name": "person:sam", "displayName": "Sam",
		"description": "d", "holders": 1}}); e.Message != "Sam is found on the Mac by itself; choose another name." {
		t.Fatal(e.Message)
	}
}
