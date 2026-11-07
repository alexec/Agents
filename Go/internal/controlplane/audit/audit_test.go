package audit

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
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
		"preferences/set": true, "machines/remove": false, "control/setAuditDays": false} {
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

// counting is a store that counts its reads.
type counting struct {
	store.Store
	gets, lists int
}

func (c *counting) Get(ctx context.Context, key string) (*store.Object, error) {
	c.gets++
	return c.Store.Get(ctx, key)
}

func (c *counting) List(ctx context.Context, prefix string) ([]store.Key, error) {
	c.lists++
	return c.Store.List(ctx, prefix)
}

// A member's list reads only their own entries, never the team's (#2051): 90 days of
// 500 entries a day from ten people, and one member who acts once in ten days. Before,
// that member's list read all 45,000 entries; now it reads their 9.
func TestAMembersListReadsOnlyTheirOwnEntries(t *testing.T) {
	ctx := context.Background()
	s := &counting{Store: store.NewMemory()}
	now := time.Date(2026, 10, 20, 12, 0, 0, 0, time.UTC)
	var at time.Time
	l := &Log{Store: s, Now: func() time.Time { return at }}
	for d := range 90 {
		for i := range 500 {
			at = now.Add(-time.Duration(d)*24*time.Hour - time.Duration(i)*time.Second)
			if err := l.Write(ctx, wire.AuditActor{User: string(rune('a' + i%10))}, "agents/stop", "Stopped an agent", "", nil); err != nil {
				t.Fatal(err)
			}
		}
		if d%10 == 0 {
			l.Write(ctx, wire.AuditActor{User: "sam"}, "agents/stop", "Stopped an agent", "", nil)
		}
	}

	s.gets, s.lists = 0, 0
	sams, more, err := l.List(ctx, NewQuery(wire.AuditQuery{User: new("sam")}, 90, now, false), owner)
	if err != nil || more || len(sams) != 9 || s.gets != 9 || s.lists > 91 {
		t.Fatalf("%v %v %d entries, %d gets, %d lists", err, more, len(sams), s.gets, s.lists)
	}
	s.gets = 0
	as, more, _ := l.List(ctx, NewQuery(wire.AuditQuery{User: new("a")}, 90, now, false), owner)
	if !more || len(as) != defaultLimit || s.gets != defaultLimit+1 || as[0].Actor.User != "a" || !as[0].At.Time().After(as[1].At.Time()) {
		t.Fatalf("%v %d entries, %d gets", more, len(as), s.gets)
	}
	// An admin's list of everyone still stops at its limit, newest first across people.
	s.gets = 0
	all, more, _ := l.List(ctx, NewQuery(wire.AuditQuery{}, 90, now, false), owner)
	if !more || len(all) != defaultLimit || s.gets != defaultLimit+1 || all[0].Actor.User != "a" || all[1].Actor.User != "b" {
		t.Fatalf("%v %d entries, %d gets, %+v", more, len(all), s.gets, all[:3])
	}
}

// A name cannot make a path of its own.
func TestANameStaysInItsFolder(t *testing.T) {
	k := Key(time.Date(2026, 10, 20, 0, 0, 0, 0, time.UTC), "../x/y")
	if strings.Count(k, "/") != 5 || strings.Contains(k, "..") || !strings.HasPrefix(k, Prefix+"2026-10-20/by/") {
		t.Fatal(k)
	}
}

func TestAShorterTimeKeepsTheOlderDaysForADay(t *testing.T) {
	now := time.Date(2026, 10, 20, 12, 0, 0, 0, time.UTC)
	year := 365
	s := &records.Settings{AuditDays: &year}
	SetDays(s, 30, now)
	if Days(s) != 30 || SweepDays(s, now) != 365 || SweepDays(s, now.Add(Grace-time.Minute)) != 365 {
		t.Fatalf("in the grace: %d %d", Days(s), SweepDays(s, now))
	}
	if SweepDays(s, now.Add(Grace)) != 30 {
		t.Fatal("after the grace")
	}
	// Shorter again in the grace still keeps the year; back to a year ends it.
	SetDays(s, 1, now.Add(time.Hour))
	if SweepDays(s, now.Add(2*time.Hour)) != 365 {
		t.Fatal(SweepDays(s, now.Add(2*time.Hour)))
	}
	SetDays(s, 365, now.Add(3*time.Hour))
	if s.AuditDaysBefore != nil || s.AuditShortened != nil || SweepDays(s, now.Add(3*time.Hour)) != 365 {
		t.Fatalf("%+v", s)
	}
	// A longer time has no grace.
	SetDays(s, 400, now)
	if s.AuditDaysBefore != nil || SweepDays(s, now) != 400 {
		t.Fatal("longer")
	}
}
