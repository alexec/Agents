package records

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/alexec/agents/controlplane-go/internal/store"
)

var ctx = context.Background()

// StoreConformanceTests.revAndTombstones: every change bumps rev, so a write made against
// A is refused after A→B→A; and a forget is a tombstone that reads as absent.
func TestRevAndTombstones(t *testing.T) {
	for name, s := range map[string]store.Store{"memory": store.NewMemory(), "folder": store.NewFolder(t.TempDir())} {
		t.Run(name, func(t *testing.T) {
			r := New(s)
			if err := r.Load(ctx); err != nil {
				t.Fatal(err)
			}
			id := NewUUID()
			client := ClientRecord{ID: id, Name: "phone", Kind: "iPhone", PublicKey: make([]byte, 65), Paired: Now()}
			r.SaveClient(ctx, ClientRecord{ID: NewUUID(), Name: "mac", Kind: "mac", PublicKey: make([]byte, 65), Paired: Now()})
			if err := r.SaveClient(ctx, client); err != nil {
				t.Fatal(err)
			}
			a, _ := s.Get(ctx, ClientKey(id))
			renamed := client
			renamed.Name = "renamed"
			r.SaveClient(ctx, renamed)
			r.SaveClient(ctx, client)
			back, _ := s.Get(ctx, ClientKey(id))
			if back.ETag == a.ETag {
				t.Fatal("A→B→A has the same tag")
			}
			if _, err := s.Put(ctx, ClientKey(id), []byte("{}"), store.Matching(a.ETag)); !store.IsConflict(err) {
				t.Fatalf("want conflict, got %v", err)
			}
			if err := r.Forget(ctx, id); err != nil {
				t.Fatal(err)
			}
			if o, _ := s.Get(ctx, ClientKey(id)); o == nil {
				t.Fatal("no tombstone")
			}
			fresh := New(s)
			fresh.Load(ctx)
			if fresh.Client(id) != nil || !fresh.WasForgotten(id) {
				t.Fatal("the tombstone did not read as forgotten")
			}
			// Paired again over its tombstone.
			if err := fresh.SaveClient(ctx, client); err != nil {
				t.Fatal(err)
			}
		})
	}
}

// A record the Swift store wrote reads here.
func TestASwiftRecordReads(t *testing.T) {
	swift := `{
  "grant" : "operator",
  "id" : "6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8",
  "kind" : "mac",
  "lastSeen" : "2026-10-16T08:16:59.123Z",
  "name" : "Alex's MacBook",
  "owner" : "e0a3c7d4-0000-4000-8000-000000000000",
  "paired" : "2026-10-15T08:16:59Z",
  "publicKey" : "BAEC",
  "rev" : 3
}`
	var c ClientRecord
	if err := json.Unmarshal([]byte(swift), &c); err != nil {
		t.Fatal(err)
	}
	if c.Rev != 3 || c.LastSeen.Nanosecond() != 123000000 || len(c.PublicKey) != 3 {
		t.Fatalf("%+v", c)
	}
	out, _ := json.Marshal(c)
	var again map[string]any
	json.Unmarshal(out, &again)
	if again["lastSeen"] != "2026-10-16T08:16:59.123Z" || again["paired"] != "2026-10-15T08:16:59.000Z" {
		t.Fatalf("%s", out)
	}
}

func TestRefDate(t *testing.T) {
	s := Stamp{}
	json.Unmarshal([]byte(`"2001-01-01T00:01:00.500Z"`), &s)
	if RefDate(s.Time) != 60.5 {
		t.Fatal(RefDate(s.Time))
	}
}
