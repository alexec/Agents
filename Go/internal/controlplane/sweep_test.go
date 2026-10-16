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
	ctx := context.Background()
	root := t.TempDir()
	s := store.NewFolder(root)
	rs := records.New(s)
	rs.SettingsOrMake(ctx, func() records.Settings { return records.Settings{Name: "test", MachineID: "m"} })
	now := time.Now()
	day := func(ago int) string { return now.Add(-time.Duration(ago) * 24 * time.Hour).UTC().Format("2006-01-02") }
	s.Put(ctx, "v1/events/"+day(10)+"/old.json", []byte("{}"), store.Absent)
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

	first, err := sweep(ctx, rs, now, mostPerSweep)
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
		"v1/events/" + day(10) + "/old.json": false, "v1/events/" + day(1) + "/new.json": true,
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
	later, err := sweep(ctx, rs, now.Add(8*24*time.Hour), mostPerSweep)
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

func TestTheSweepStopsAtItsBound(t *testing.T) {
	ctx := context.Background()
	s := store.NewMemory()
	for n := range 12 {
		s.Put(ctx, "v1/events/2000-01-01/"+itoa(n)+".json", []byte("{}"), store.Absent)
	}
	report, _ := sweep(ctx, records.New(s), time.Now(), 5)
	if left, _ := s.List(ctx, "v1/events/"); report.events != 5 || len(left) != 7 {
		t.Fatal(report, len(left))
	}
}

// A window's whole lists of a host are kept, and said by hosts/lastHeard while the host
// is offline (#962); a narrowed list is not.
func TestWhatAHostLastListedIsKept(t *testing.T) {
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
	if string(heard["agents"]) != "[]" || heard["heardAt"] == nil || heard["projects"] != nil {
		t.Fatalf("%s", heard)
	}
	if !keepsList("projects/list", nil) || keepsList("agents/list", json.RawMessage(`{"lean":true,"includeArchived":true}`)) {
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
