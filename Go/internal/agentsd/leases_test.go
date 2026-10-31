package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/wire"
)

// Ports LeaseBookTests and the person's side of LeaseTests on a server.

func TestDeclaringAResource(t *testing.T) {
	root := t.TempDir()
	d, c := start(t, root)
	defer d.Shutdown()
	var snap wire.LeaseSnapshot
	json.Unmarshal(c.call(t, 1, "resources/snapshot", nil), &snap)
	if len(snap.Resources) != 1 || snap.Resources[0].Name != "screen" || snap.Resources[0].DisplayName != "Screen, mouse and keyboard" {
		t.Fatalf("%+v", snap)
	}
	two := int64(2)
	json.Unmarshal(c.call(t, 2, "resources/declare", map[string]any{"resource": map[string]any{"name": " Build ", "displayName": " build ",
		"description": " When building ", "holders": two, "defaultMinutes": 10}}), &snap)
	r := snap.Resources[0]
	if r.Name != "build" || r.Declared == nil || r.Declared.Description != "When building" || *r.Places != 2 || r.DisplayName != "build" {
		t.Fatalf("%+v", r)
	}
	if b, _ := os.ReadFile(filepath.Join(root, "resources.json")); !strings.Contains(string(b), `"defaultMinutes":10`) {
		t.Fatalf("%s", b)
	}
	for i, tc := range []struct {
		resource map[string]any
		want     string
	}{
		{map[string]any{"name": "screen", "displayName": "Screen", "description": "x", "holders": 1}, "Screen is found on the Mac by itself; choose another name."},
		{map[string]any{"name": "x", "displayName": "x", "description": " ", "holders": 1}, "Say what it is for, so agents know when to take it."},
		{map[string]any{"name": "x", "displayName": "x", "description": "d", "holders": 21}, "Between 1 and 20 agents may hold it at once."},
		{map[string]any{"name": "x", "displayName": "x", "description": "d", "holders": 1, "maximumMinutes": 300}, "The longest a lease can run is between 1 and 240 minutes."},
		{map[string]any{"name": "x", "displayName": "x", "description": "d", "holders": 1, "maximumMinutes": 30, "defaultMinutes": 40}, "The usual length is between 1 minute and the longest, 30."},
		{map[string]any{"name": "build", "displayName": "build", "description": "d", "holders": 1}, "build is declared already."},
	} {
		if e := c.callError(t, 10+i, "resources/declare", map[string]any{"resource": tc.resource}); e.Code != wire.FailureLeaseRefused || e.Message != tc.want {
			t.Fatalf("%d: %+v", i, e)
		}
	}
	c.call(t, 20, "resources/remove", map[string]any{"name": "BUILD"})
	if e := c.callError(t, 21, "resources/remove", map[string]any{"name": "build"}); e.Message != "build is not declared." {
		t.Fatal(e.Message)
	}
	if e := c.callError(t, 22, "resources/lease", map[string]any{"token": "t", "name": "build"}); e.Message != "That conversation is not open any more, so nothing was leased." {
		t.Fatal(e.Message)
	}
}

// A book the Swift host wrote is read, ended by the person, and handed on: the next in
// line, with no wait open for it, is started again with the event (#2361).
func TestABookSwiftWroteIsHandedOn(t *testing.T) {
	fakeRuntimes(t)
	root := t.TempDir()
	d, c := start(t, root)
	defer d.Shutdown()
	holder := seeded(t, d, t.TempDir(), nil)
	next := seeded(t, d, t.TempDir(), nil)
	at := time.Now().UTC()
	book := map[string]any{"entries": map[string]any{"simulator:abc": map[string]any{
		"kind": "simulator", "displayName": "iPhone 17",
		"lease": map[string]any{"resource": "simulator:abc", "displayName": "iPhone 17", "holder": holder.ID,
			"grantedAt": at.Format("2006-01-02T15:04:05.000Z"), "expiresAt": at.Add(20 * time.Minute).Format("2006-01-02T15:04:05.000Z"), "warned": false},
		"line": []any{map[string]any{"agentID": next.ID, "askedAt": at.Format("2006-01-02T15:04:05.000Z"),
			"waitID": "11111111-1111-1111-1111-111111111111"}}}}, "notices": map[string]any{}}
	b, _ := json.Marshal(book)
	os.WriteFile(filepath.Join(root, "leases.json"), b, 0o644)
	var snap wire.LeaseSnapshot
	json.Unmarshal(c.call(t, 1, "resources/snapshot", nil), &snap)
	var sim wire.ResourceState
	for _, r := range snap.Resources {
		if r.Name == "simulator:abc" {
			sim = r
		}
	}
	// Not found on this host: gone, and its call closed by the restart.
	if !sim.IsGone || len(sim.Holds) != 1 || sim.Holds[0].Holder != holder.ID || len(sim.Line) != 1 || sim.Line[0].IsCallOpen {
		t.Fatalf("%+v", sim)
	}
	if snap.Resources[0].Name != "screen" {
		t.Fatalf("order %+v", snap.Resources)
	}
	if e := c.callError(t, 2, "resources/end", map[string]any{"name": "simulator:abc", "agentID": next.ID}); e.Message != "That agent does not hold simulator:abc." {
		t.Fatal(e.Message)
	}
	json.Unmarshal(c.call(t, 3, "resources/end", map[string]any{"name": "simulator:abc"}), &snap)
	waitFor(t, "the next in line started", func() bool {
		for _, m := range userMessages(d, next.ID) {
			if strings.HasPrefix(m, "The event you were waiting for happened.") && strings.Contains(m, "You hold iPhone 17 until ") {
				return true
			}
		}
		return false
	})
	if !strings.Contains(strings.Join(kinds(d, holder.ID), " "), "runtimeNote") {
		t.Fatal("the holder's record does not say it was ended")
	}
	var onDisk struct {
		Entries map[string]struct {
			Leases []wire.Lease `json:"leases"`
		} `json:"entries"`
		Notices map[string][]json.RawMessage `json:"notices"`
	}
	b, _ = os.ReadFile(filepath.Join(root, "leases.json"))
	diskjson.Unmarshal(b, &onDisk)
	if l := onDisk.Entries["simulator:abc"].Leases; len(l) != 1 || l[0].Holder != next.ID || !strings.Contains(string(b), "endedByPerson") {
		t.Fatalf("%s", b)
	}
	// Stopped, it lets go, and the book is empty.
	c.call(t, 4, "agents/stop", map[string]any{"agentID": next.ID})
	waitFor(t, "the lease let go", func() bool {
		b, _ := os.ReadFile(filepath.Join(root, "leases.json"))
		var book struct {
			Entries map[string]json.RawMessage `json:"entries"`
		}
		json.Unmarshal(b, &book)
		return len(book.Entries) == 0
	})
	waitFor(t, "its turn over", func() bool {
		l := d.live(next.ID)
		l.mu.Lock()
		defer l.mu.Unlock()
		return !l.running
	})
}

func TestTheBookRules(t *testing.T) {
	r := leaseRules{Holders: 1}
	if l, capped := r.length(nil); l != 30*time.Minute || capped {
		t.Fatal(l)
	}
	big := int64(500)
	if l, capped := r.length(&big); l != 240*time.Minute || !capped {
		t.Fatal(l)
	}
	ten, five := int64(10), int64(5)
	r = leaseRules{Holders: 1, DefaultMinutes: &ten, MaximumMinutes: &five}
	if l, _ := r.length(nil); l != 5*time.Minute {
		t.Fatal(l)
	}
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	d.leaseMu.Lock()
	d.loadLeases()
	soon := now().Time().Add(3 * time.Minute)
	d.book.Entries["x"] = &leaseEntry{Kind: "named", DisplayName: "x", Rules: standardRules,
		Leases: []wire.Lease{{Resource: "x", DisplayName: "x", Holder: "A", GrantedAt: now(), ExpiresAt: wire.DateOf(soon)}}}
	d.lapse(now().Time())
	warned := d.book.Entries["x"].Leases[0].Warned && len(d.book.Notices["A"]) == 1
	events := d.lapse(soon.Add(time.Second))
	d.leaseMu.Unlock()
	if !warned || len(events) != 1 || events[0].ending != "expired" || d.book.Entries["x"] != nil || len(d.book.Notices["A"]) != 2 {
		t.Fatalf("%v %+v %+v", warned, events, d.book)
	}
}
