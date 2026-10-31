package controlplane

// StoreHousekeepingTests' sweep cases, ported, and the kept host lists (#962).

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

func TestTheSweepRemovesTheDeadAndKeepsTheLive(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	root := t.TempDir()
	s := store.NewFolder(root)
	rs := records.New(s)
	rs.SettingsOrMake(ctx, func() records.Settings { return records.Settings{Name: "test", MachineID: "m"} })
	now := time.Now()
	day := func(ago int) string { return now.Add(-time.Duration(ago) * 24 * time.Hour).UTC().Format("2006-01-02") }
	s.Put(ctx, "v1/events/"+day(91)+"/old.json", []byte("{}"), store.Absent)
	s.Put(ctx, "v1/events/"+day(1)+"/new.json", []byte("{}"), store.Absent)
	code := func(id string, expires time.Time, spent bool) {
		data, _ := records.Encode(storedCode{Purpose: "client", Expires: records.At(expires)})
		s.Put(ctx, codeKey(id), data, store.Absent)
		if spent {
			s.Put(ctx, spentKey(id), []byte("{}"), store.Absent)
		}
	}
	code("long-gone", now.Add(-48*time.Hour), true)
	code("just-expired", now.Add(-10*time.Minute), false)
	code("good", now.Add(10*time.Minute), true)
	s.Put(ctx, spentKey("orphan"), []byte("{}"), store.Absent)

	client := func(name string) records.ClientRecord {
		return records.ClientRecord{ID: records.NewUUID(), Name: name, Kind: records.KindIPhone, PublicKey: []byte{4}, Paired: records.Now()}
	}
	live, forgotten, legacy := client("live"), client("forgotten"), client("legacy")
	rs.SaveClient(ctx, live)
	rs.SaveClient(ctx, forgotten)
	rs.ForgetClient(ctx, forgotten.ID)
	// A tombstone from before forgottenAt was kept.
	yes := true
	legacy.Forgotten, legacy.Rev = &yes, 1
	data, _ := records.Encode(legacy)
	s.Put(ctx, records.ClientKey(legacy.ID), data, store.Absent)
	rs.Load(ctx)
	if !rs.WasForgotten(forgotten.ID) {
		t.Fatal("not forgotten")
	}
	// Leftovers: an old temporary file goes, a new one stays.
	folder := filepath.Join(root, "v1", "clients")
	oldTmp, newTmp := filepath.Join(folder, ".x.json.1.tmp"), filepath.Join(folder, ".y.json.2.tmp")
	os.WriteFile(oldTmp, nil, 0o600)
	os.WriteFile(newTmp, nil, 0o600)
	then := now.Add(-2 * time.Hour)
	os.Chtimes(oldTmp, then, then)

	first, err := sweep(ctx, rs, now, mostPerSweep, nil)
	if err != nil {
		t.Fatal(err)
	}
	if first.events != 1 || first.codes != 3 || first.tombstones != 0 || first.dated != 1 || first.leftovers != 1 {
		t.Fatalf("%+v", first)
	}
	keys := map[string]bool{}
	listed, _ := s.List(ctx, "v1/")
	for _, k := range listed {
		keys[k.Key] = true
	}
	for key, want := range map[string]bool{
		"v1/events/" + day(91) + "/old.json": false, "v1/events/" + day(1) + "/new.json": true,
		codeKey("long-gone"): false, spentKey("long-gone"): false, spentKey("orphan"): false,
		codeKey("just-expired"): true, codeKey("good"): true, spentKey("good"): true,
		records.ClientKey(forgotten.ID): true,
	} {
		if keys[key] != want {
			t.Errorf("%s: %v", key, keys[key])
		}
	}
	if _, err := os.Stat(oldTmp); err == nil {
		t.Fatal("the old temporary file stayed")
	}
	if _, err := os.Stat(newTmp); err != nil {
		t.Fatal("the new temporary file went")
	}

	// Eight days on, both tombstones go; the live client and the settings stay.
	later, err := sweep(ctx, rs, now.Add(8*24*time.Hour), mostPerSweep, nil)
	if err != nil || later.tombstones != 2 {
		t.Fatalf("%+v %v", later, err)
	}
	if o, _ := s.Get(ctx, records.ClientKey(forgotten.ID)); o != nil {
		t.Fatal("a tombstone stayed")
	}
	if rs.Client(live.ID) == nil || rs.WasForgotten(forgotten.ID) {
		t.Fatal("the records did not follow")
	}
	if o, _ := s.Get(ctx, records.SettingsKey); o == nil {
		t.Fatal("the settings went")
	}
	// A device forgotten and paired again after that pairs as new.
	if err := rs.SaveClient(ctx, forgotten); err != nil {
		t.Fatal(err)
	}
}

// #2711: a removed project's record goes a week on, as a forgotten client's does; a live
// one stays.
func TestTheSweepRemovesRemovedProjects(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	s := store.NewMemory()
	rs := records.New(s)
	rs.SettingsOrMake(ctx, func() records.Settings { return records.Settings{Name: "test", MachineID: "m"} })
	for _, id := range []string{"p-live", "p-gone"} {
		rs.ChangeProject(ctx, id, func(*records.Project) (*records.Project, error) {
			return &records.Project{ID: id, Name: id, Owner: "u", MadeAt: records.Now()}, nil
		})
	}
	rs.ChangeProject(ctx, "p-gone", func(p *records.Project) (*records.Project, error) {
		yes, now := true, records.Now()
		next := *p
		next.Removed, next.RemovedAt = &yes, &now
		return &next, nil
	})
	if got := rs.ProjectsOwnedBy("u"); got != 2 {
		t.Fatal(got)
	}
	now := time.Now()
	if report, err := sweep(ctx, rs, now, mostPerSweep, nil); err != nil || report.tombstones != 0 {
		t.Fatalf("%+v %v", report, err)
	}
	if report, err := sweep(ctx, rs, now.Add(8*24*time.Hour), mostPerSweep, nil); err != nil || report.tombstones != 1 {
		t.Fatalf("%+v %v", report, err)
	}
	if o, _ := s.Get(ctx, records.ProjectKey("p-gone")); o != nil {
		t.Fatal("the removed project stayed")
	}
	if rs.Project("p-live") == nil || rs.ProjectsOwnedBy("u") != 1 {
		t.Fatal("the records did not follow")
	}
}

func TestTheSweepStopsAtItsBound(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	s := store.NewMemory()
	for n := range 12 {
		s.Put(ctx, "v1/events/2000-01-01/"+itoa(n)+".json", []byte("{}"), store.Absent)
	}
	report, _ := sweep(ctx, records.New(s), time.Now(), 5, nil)
	if left, _ := s.List(ctx, "v1/events/"); report.events != 5 || len(left) != 7 {
		t.Fatal(report, len(left))
	}
}

// #2291: more expired than one round deletes goes within a bounded number of rounds of the
// same hour, not a round an hour for ever.
func TestTheSweepCatchesUpWithinTheHour(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	s := store.NewMemory()
	now := time.Date(2026, 10, 21, 12, 0, 0, 0, time.UTC)
	for _, day := range []string{"2000-01-01", "2000-01-02", "2000-01-03"} {
		for n := range 17 {
			s.Put(ctx, "v1/events/"+day+"/"+itoa(n)+".json", []byte("{}"), store.Absent)
		}
	}
	kept := now.Format(sweptDayLayout)
	s.Put(ctx, "v1/events/"+kept+"/0.json", []byte("{}"), store.Absent)
	pauses := 0
	report, rounds, err := sweepRounds(ctx, records.New(s), func() time.Time { return now }, 10, &eventSweep{},
		time.Second, func(time.Duration) bool { pauses++; return true })
	left, _ := s.List(ctx, eventsPrefix)
	// 51 expired, 10 a round: 6 rounds, the last one not full.
	if err != nil || report.events != 51 || rounds != 6 || pauses != 5 || len(left) != 1 || left[0].Key != "v1/events/"+kept+"/0.json" {
		t.Fatalf("%+v rounds %d pauses %d left %v %v", report, rounds, pauses, left, err)
	}
}

// The rounds stop when told to (the copy stops serving, or the service stops), and when
// the next hour's sweep is due: the rest is the next hour's.
func TestTheSweepRoundsStop(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	fill := func() store.Store {
		s := store.NewMemory()
		for n := range 50 {
			s.Put(ctx, "v1/events/2000-01-01/"+itoa(n)+".json", []byte("{}"), store.Absent)
		}
		return s
	}
	start := time.Date(2026, 10, 21, 12, 0, 0, 0, time.UTC)

	s := fill()
	report, rounds, _ := sweepRounds(ctx, records.New(s), func() time.Time { return start }, 10, &eventSweep{},
		time.Second, func(time.Duration) bool { return false })
	if report.events != 10 || rounds != 1 {
		t.Fatalf("told to stop: %+v %d", report, rounds)
	}

	s = fill()
	clock := start
	report, rounds, _ = sweepRounds(ctx, records.New(s), func() time.Time { return clock }, 10, &eventSweep{},
		25*time.Minute, func(pause time.Duration) bool { clock = clock.Add(pause); return true })
	// Rounds at :00, :25 and :50; a fourth would start after the hour.
	if report.events != 30 || rounds != 3 {
		t.Fatalf("the hour: %+v %d", report, rounds)
	}
}

// #2293: an expired lease of a host with no record goes, a live one or a known host's
// stays; an org route's tombstone goes with its secret.
func TestTheSweepRemovesOrphans(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	s := store.NewMemory()
	rs := records.New(s)
	now := time.Date(2026, 10, 21, 12, 0, 0, 0, time.UTC)
	if err := rs.SaveHost(ctx, records.MachineRecord{ID: "KNOWN", Name: "known"}); err != nil {
		t.Fatal(err)
	}
	lease := func(host string, expires time.Time) {
		data, _ := records.Encode(hostLease{Host: host, Copy: "c", Epoch: 3, Expires: records.At(expires)})
		s.Put(ctx, leaseKey(host), data, store.Always)
	}
	lease("KNOWN", now.Add(-time.Hour))
	lease("GONE", now.Add(-time.Hour))
	lease("GOING", now.Add(time.Minute))
	s.Put(ctx, orgRouteKey("r1"), []byte(`{"removed":true}`), store.Always)
	s.Put(ctx, orgSecretKey("r1"), []byte(`{}`), store.Always)
	s.Put(ctx, orgRouteKey("r2"), []byte(`{"id":"r2","name":"live"}`), store.Always)
	s.Put(ctx, orgSecretKey("r2"), []byte(`{}`), store.Always)
	report, err := sweep(ctx, rs, now, mostPerSweep, nil)
	if err != nil || report.orphans != 2 {
		t.Fatalf("%+v %v", report, err)
	}
	for key, kept := range map[string]bool{leaseKey("KNOWN"): true, leaseKey("GONE"): false, leaseKey("GOING"): true,
		orgRouteKey("r1"): false, orgSecretKey("r1"): false, orgRouteKey("r2"): true, orgSecretKey("r2"): true} {
		if o, _ := s.Get(ctx, key); (o != nil) != kept {
			t.Errorf("%s kept %v", key, o != nil)
		}
	}
}

// listCounter is a store that counts its lists.
type listCounter struct {
	store.Store
	lists []string
}

func (l *listCounter) List(ctx context.Context, prefix string) ([]store.Key, error) {
	l.lists = append(l.lists, prefix)
	return l.Store.List(ctx, prefix)
}

// #2053: the hourly sweep lists the audit's events once, at its first sweep. After that it
// lists only each day that has expired since, not the 90 days kept.
func TestTheSweepListsOnlyTheExpiredDays(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	s := &listCounter{Store: store.NewMemory()}
	now := time.Date(2026, 10, 21, 12, 0, 0, 0, time.UTC)
	for ago := range 93 {
		day := now.AddDate(0, 0, -ago).Format("2006-01-02")
		for n := range 20 {
			s.Put(ctx, "v1/events/"+day+"/by/x/"+itoa(n)+".json", []byte("{}"), store.Absent)
		}
	}
	rs := records.New(s)
	events := &eventSweep{}
	eventLists := func() (n int) {
		for _, prefix := range s.lists {
			if strings.HasPrefix(prefix, eventsPrefix) {
				n++
			}
		}
		s.lists = nil
		return n
	}

	// The first: one list of every event, then each of the two expired days.
	first, err := sweep(ctx, rs, now, mostPerSweep, events)
	if err != nil || first.events != 40 || eventLists() != 3 {
		t.Fatalf("%+v %v", first, err)
	}
	// An hour on, nothing has expired: no list.
	if again, _ := sweep(ctx, rs, now.Add(time.Hour), mostPerSweep, events); again.events != 0 || eventLists() != 0 {
		t.Fatalf("%+v", again)
	}
	// A day on, that day's folder alone.
	if later, _ := sweep(ctx, rs, now.Add(24*time.Hour), mostPerSweep, events); later.events != 20 || eventLists() != 1 {
		t.Fatalf("%+v", later)
	}
	// At its bound, a day is finished by the next sweep.
	if part, _ := sweep(ctx, rs, now.Add(48*time.Hour), 15, events); part.events != 15 {
		t.Fatalf("%+v", part)
	}
	if rest, _ := sweep(ctx, rs, now.Add(49*time.Hour), mostPerSweep, events); rest.events != 5 {
		t.Fatalf("%+v", rest)
	}
	if left, _ := s.Store.List(ctx, eventsPrefix); len(left) != 89*20 {
		t.Fatalf("%d left", len(left))
	}
}

// A window's whole lists of a host are kept, and said by hosts/lastHeard while the host
// is offline (#962); a narrowed list is not.
func TestWhatAHostLastListedIsKept(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	box := p.host("MACHINE-2")
	_, window := p.client("Window")
	call(t, window, box.member.Host, "agents/list", map[string]any{"lean": true})
	call(t, window, box.member.Host, "agents/list", map[string]any{"lean": true, "query": "x"})
	p.waitFor(func() bool {
		o, _ := p.store.Get(context.Background(), copyKey(box.member.Host))
		return o != nil
	}, "the copy kept")
	box.stop()
	var heard map[string]json.RawMessage
	json.Unmarshal(call(t, window, "", "hosts/lastHeard", map[string]string{"host": box.member.Host}), &heard)
	if string(heard["agents"]) != "[]" || heard["heardAt"] == nil || heard["folders"] != nil {
		t.Fatalf("%s", heard)
	}
	if !keepsList("folders/list", nil) || keepsList("agents/list", json.RawMessage(`{"lean":true,"includeArchived":true}`)) {
		t.Fatal("keeps the wrong lists")
	}
	// A removed host's copy goes.
	call(t, window, "", "hosts/remove", map[string]string{"host": box.member.Host})
	if o, _ := p.store.Get(context.Background(), copyKey(box.member.Host)); o != nil {
		t.Fatal("the copy stayed")
	}
	if e := callError(t, window, "", "hosts/lastHeard", map[string]string{"host": box.member.Host}); !strings.Contains(e, "-32091") {
		t.Fatal(e)
	}
}
