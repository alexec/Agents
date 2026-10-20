package audit

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

func owner(string) wire.AuditActor { return wire.AuditActor{User: "owner"} }

// Entries come back newest first, a page at a time, filtered by person and time, and an
// export comes oldest first as JSON lines.
func TestEntriesAreListedNewestFirst(t *testing.T) {
	ctx := context.Background()
	s := store.NewMemory()
	now := time.Date(2026, 10, 20, 12, 0, 0, 0, time.UTC)
	at := now.Add(-3 * 24 * time.Hour)
	l := &Log{Store: s, Now: func() time.Time { return at }}
	alex, sam := wire.AuditActor{User: "alex"}, wire.AuditActor{User: "sam"}
	for i := range 5 {
		at = now.Add(-time.Duration(4-i) * 24 * time.Hour)
		who := alex
		if i%2 == 1 {
			who = sam
		}
		if err := l.Write(ctx, who, "agents/stop", "Stopped an agent", "box", new(string(rune('A'+i)))); err != nil {
			t.Fatal(err)
		}
	}
	// One of the control plane's own events is not an entry.
	s.Put(ctx, Prefix+now.Format(dayLayout)+"/0000000000000-x.json", []byte(`{"kind":"hostRemoved","subject":"box","at":"2026-10-20T00:00:00.000Z","by":"code"}`), store.Absent)

	all, more, err := l.List(ctx, NewQuery(wire.AuditQuery{}, 90, now, false), owner)
	if err != nil || more || len(all) != 5 {
		t.Fatalf("%v %v %+v", err, more, all)
	}
	if *all[0].Target != "E" || *all[4].Target != "A" || all[0].Actor.User != "alex" || string(*all[0].Host) != "box" {
		t.Fatalf("%+v", all[0])
	}

	page, more, _ := l.List(ctx, NewQuery(wire.AuditQuery{Limit: new(int64(2))}, 90, now, false), owner)
	if len(page) != 2 || !more || *page[1].Target != "D" {
		t.Fatalf("%v %+v", more, page)
	}
	sams, _, _ := l.List(ctx, NewQuery(wire.AuditQuery{User: new("sam")}, 90, now, false), owner)
	if len(sams) != 2 || sams[0].Actor.User != "sam" {
		t.Fatalf("%+v", sams)
	}
	// Two days back is the last three entries; the days kept bound any since asked for.
	recent, _, _ := l.List(ctx, NewQuery(wire.AuditQuery{Since: new(wire.DateOf(now.Add(-49 * time.Hour)))}, 90, now, false), owner)
	if len(recent) != 3 {
		t.Fatalf("%+v", recent)
	}
	kept, _, _ := l.List(ctx, NewQuery(wire.AuditQuery{Since: new(wire.DateOf(now.Add(-400 * 24 * time.Hour)))}, 2, now, false), owner)
	if len(kept) != 3 {
		t.Fatalf("%+v", kept)
	}

	oldest, _, _ := l.List(ctx, NewQuery(wire.AuditQuery{}, 90, now, true), owner)
	lines := strings.Split(strings.TrimSpace(Lines(oldest)), "\n")
	var first wire.AuditEntry
	if len(lines) != 5 || json.Unmarshal([]byte(lines[0]), &first) != nil || *first.Target != "A" || first.Method != "agents/stop" {
		t.Fatalf("%v", lines)
	}
}

func TestWhatIsKeptAndWhatItActsOn(t *testing.T) {
	for method, host := range map[string]bool{"agents/start": true, "elicitations/answer": true, "workflows/approve": true,
		"preferences/set": true, "hosts/remove": false, "control/setAuditDays": false} {
		if _, ok := Action(method, host); !ok {
			t.Error(method)
		}
	}
	for method, host := range map[string]bool{"agents/list": true, "agents/prompt": true, "presence/report": true,
		"audit/list": false, "control/status": false} {
		if _, ok := Action(method, host); ok {
			t.Error(method)
		}
	}
	if got := Target(json.RawMessage(`{"prompt":"secret plans","cwd":"file:///Users/a/p"}`)); got == nil || *got != "/Users/a/p" {
		t.Fatal(got)
	}
	if got := Target(json.RawMessage(`{"server":"github","value":"ghp_x"}`)); got == nil || *got != "github" {
		t.Fatal(got)
	}
	if Target(json.RawMessage(`"bare"`)) != nil {
		t.Fatal("a bare value named a target")
	}
}

func TestOldEntriesExpireByTheDaysKept(t *testing.T) {
	now := time.Date(2026, 10, 20, 12, 0, 0, 0, time.UTC)
	if !Expired(Prefix+"2026-07-21/x.json", 90, now) || Expired(Prefix+"2026-07-22/x.json", 90, now) {
		t.Fatal("90 days")
	}
	if !Expired(Prefix+"2026-10-18/x.json", 1, now) || Expired(Prefix+"2026-10-19/x.json", 1, now) {
		t.Fatal("1 day")
	}
	if Days(nil) != DefaultDays {
		t.Fatal(Days(nil))
	}
}
