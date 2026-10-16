package records

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

var ctx = context.Background()

// swiftStore is a folder holding records as the Swift control plane wrote them
// (testdata/v1, from a scratch control plane, names and machine changed).
func swiftStore(t *testing.T) *store.Folder {
	root := t.TempDir()
	filepath.WalkDir("testdata", func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, _ := filepath.Rel("testdata", p)
		os.MkdirAll(filepath.Join(root, filepath.Dir(rel)), 0o700)
		data, _ := os.ReadFile(p)
		return os.WriteFile(filepath.Join(root, rel), data, 0o600)
	})
	return store.NewFolder(root)
}

func TestSwiftRecordsAreRead(t *testing.T) {
	r := New(swiftStore(t))
	if err := r.Load(ctx); err != nil {
		t.Fatal(err)
	}
	c := r.Client("1dd016d9-a36b-43f3-a390-afcb236603c2")
	if c == nil || c.Name != "Test’s MacBook Air" || c.Kind != KindMac || len(c.PublicKey) != 65 || c.Rev != 2 ||
		c.LastSeen.UnixMilli() != time.Date(2026, 10, 14, 2, 58, 31, 129e6, time.UTC).UnixMilli() ||
		c.Paired.Unix() != time.Date(2026, 10, 14, 2, 58, 31, 0, time.UTC).Unix() || *c.KnownEpoch != 0 {
		t.Fatalf("%+v", c)
	}
	// A kind a later build added is read as unknown, and the old grant is not read.
	if later := r.Client("2DD016D9-A36B-43F3-A390-AFCB236603C2"); later == nil || later.Kind != KindUnknown || !later.IsDevice() {
		t.Fatalf("%+v", later)
	}
	h := r.Host("mac")
	if h == nil || h.Platform != "macOS arm64" || h.SignInFrom["claude"] != "mac" || h.Rev != 2 || *h.MachineID == "" {
		t.Fatalf("%+v", h)
	}
	s := r.Settings()
	if s == nil || s.Name != "run-test" || s.Port != 8790 || *s.HomeHost != "mac" || len(s.ControlKey) != 65 ||
		len(s.Endpoints) != 1 || *s.Endpoints[0].Pin == "" || *s.Rev != 3 {
		t.Fatalf("%+v", s)
	}
}

// What Go writes Swift reads: the same fields, the grant written as operator, dates with
// milliseconds, and what Go does not know written back as it was.
func TestWritingKeepsWhatItDoesNotKnow(t *testing.T) {
	s := swiftStore(t)
	r := New(s)
	r.Load(ctx)
	h := r.Host("mac")
	h.Version = "0.2"
	if err := r.SaveHost(ctx, *h); err != nil {
		t.Fatal(err)
	}
	o, _ := s.Get(ctx, HostKey("mac"))
	var written map[string]any
	json.Unmarshal(o.Data, &written)
	if written["version"] != "0.2" || written["rev"] != 3.0 || written["laterField"] == nil ||
		written["reach"] == nil || written["signInFrom"] == nil {
		t.Fatalf("%s", o.Data)
	}
	// Keys sorted, slashes and quotes as they are, as Swift's encoder writes them.
	text := string(o.Data)
	if strings.Index(text, `"id"`) > strings.Index(text, `"name"`) || !strings.Contains(text, "d/4+E+/1q") {
		t.Fatal(text)
	}

	c := r.Client("1DD016D9-A36B-43F3-A390-AFCB236603C2")
	c.Name = "Renamed"
	if err := r.SaveClient(ctx, *c); err != nil {
		t.Fatal(err)
	}
	o, _ = s.Get(ctx, ClientKey(c.ID))
	written = nil
	json.Unmarshal(o.Data, &written)
	if written["grant"] != "operator" || written["paired"] != "2026-10-14T02:58:31.000Z" || written["id"] != c.ID {
		t.Fatalf("%s", o.Data)
	}
}

// A host saved with nothing changed but its revision is not written.
func TestAnUnchangedHostIsNotWritten(t *testing.T) {
	s := store.NewMemory()
	r := New(s)
	r.SaveHost(ctx, HostRecord{ID: "box", Name: "Box", Platform: "linux"})
	before, _ := s.Get(ctx, HostKey("box"))
	h := r.Host("box")
	h.Rev = 99
	r.SaveHost(ctx, *h)
	after, _ := s.Get(ctx, HostKey("box"))
	if before.ETag != after.ETag || r.Host("box").Rev != 1 {
		t.Fatal("written again")
	}
}

// Two copies on one store: the second's change against what it read first conflicts,
// and nothing is written; once it has read again, it can.
func TestAChangeElsewhereFirstConflicts(t *testing.T) {
	s := store.NewMemory()
	a, b := New(s), New(s)
	id := NewUUID()
	a.SaveClient(ctx, ClientRecord{ID: id, Name: "Phone", Kind: KindIPhone, PublicKey: []byte{4}, Paired: Now()})
	b.Load(ctx)
	c := a.Client(id)
	c.Name = "Renamed at a"
	if err := a.SaveClient(ctx, *c); err != nil {
		t.Fatal(err)
	}
	c2 := b.Client(id)
	c2.Name = "Renamed at b"
	if err := b.SaveClient(ctx, *c2); !store.IsConflict(err) {
		t.Fatalf("want a conflict, got %v", err)
	}
	b.Load(ctx)
	if b.Client(id).Name != "Renamed at a" {
		t.Fatal(b.Client(id))
	}
}

// Forgotten clients are tombstones: read as absent and as forgotten, and a client
// paired again with the same id is written over its tombstone.
func TestForgettingAndPairingAgain(t *testing.T) {
	s := store.NewMemory()
	r := New(s)
	id := NewUUID()
	r.SaveClient(ctx, ClientRecord{ID: id, Name: "Phone", Kind: KindIPhone, PublicKey: []byte{4}, Paired: Now()})
	if err := r.ForgetClient(ctx, id); err != nil {
		t.Fatal(err)
	}
	other := New(s)
	other.Load(ctx)
	if other.Client(id) != nil || !other.WasForgotten(id) || len(other.TombstoneKeys()) != 1 {
		t.Fatal("not a tombstone")
	}
	if err := other.SaveClient(ctx, ClientRecord{ID: id, Name: "Phone", Kind: KindIPhone, PublicKey: []byte{4}, Paired: Now()}); err != nil {
		t.Fatal(err)
	}
	r.Load(ctx)
	if r.Client(id) == nil || r.WasForgotten(id) {
		t.Fatal("not paired again")
	}
	// Forgetting one that is not there does nothing.
	if err := r.ForgetClient(ctx, NewUUID()); err != nil {
		t.Fatal(err)
	}
	// And a host removed twice is there once.
	r.SaveHost(ctx, HostRecord{ID: "box", Name: "Box"})
	if gone, _ := r.RemoveHost(ctx, "box"); !gone {
		t.Fatal("not removed")
	}
	if gone, _ := r.RemoveHost(ctx, "box"); gone {
		t.Fatal("removed twice")
	}
}

// #171: a record that can't be decoded is neither known nor forgotten, is said once,
// and a record held from before keeps being used.
func TestAnUnreadableRecordIsNeitherKnownNorForgotten(t *testing.T) {
	s := store.NewMemory()
	r := New(s)
	var said []string
	r.OnUnreadable(func(line string) { said = append(said, line) })
	id := NewUUID()
	r.SaveClient(ctx, ClientRecord{ID: id, Name: "Phone", Kind: KindIPhone, PublicKey: []byte{4}, Paired: Now()})
	s.Put(ctx, ClientKey(id), []byte("{not json"), store.Always)
	broken := NewUUID()
	s.Put(ctx, ClientKey(broken), []byte(`{"id":"`+broken+`"}`), store.Absent)
	r.Load(ctx)
	r.Load(ctx)
	if r.Client(id) == nil || !r.ClientUnreadable(id) {
		t.Fatal("the held record went")
	}
	if r.Client(broken) != nil || r.WasForgotten(broken) || !r.ClientUnreadable(broken) {
		t.Fatal("a record missing its fields was read")
	}
	if len(said) != 2 {
		t.Fatal(said)
	}
}

// Copies starting together on an empty store settle on one set of settings and one
// owner.
func TestSettingsAreMadeOnce(t *testing.T) {
	s := store.NewMemory()
	var wg sync.WaitGroup
	owners := make([]string, 10)
	for n := range owners {
		wg.Add(1)
		go func() {
			defer wg.Done()
			got, err := New(s).SettingsOrMake(ctx, func() Settings { return Settings{Name: "cp", Port: 8790, MachineID: "m"} })
			if err != nil {
				t.Error(err)
				return
			}
			owners[n] = *got.Owner
		}()
	}
	wg.Wait()
	for _, o := range owners[1:] {
		if o != owners[0] {
			t.Fatal(owners)
		}
	}
	if p, _ := s.Get(ctx, PersonKey(owners[0])); p == nil {
		t.Fatal("no person")
	}
	// Settings that are there and can't be read are never made over.
	bad := store.NewMemory()
	bad.Put(ctx, SettingsKey, []byte("{}"), store.Absent)
	if _, err := New(bad).SettingsOrMake(ctx, func() Settings { return Settings{Name: "cp"} }); err == nil {
		t.Fatal("made over")
	}
}

func TestSettingsChangedElsewhereAreChangedAgain(t *testing.T) {
	s := store.NewMemory()
	a, b := New(s), New(s)
	a.SettingsOrMake(ctx, func() Settings { return Settings{Name: "cp", Port: 8790, MachineID: "m"} })
	b.Load(ctx)
	url := "https://a:1"
	a.ChangeSettings(ctx, func(s *Settings) { s.URL = &url })
	got, err := b.ChangeSettings(ctx, func(s *Settings) { s.Port = 9000 })
	if err != nil || got.Port != 9000 || got.URL == nil || *got.URL != url || *got.Rev != 3 {
		t.Fatalf("%+v %v", got, err)
	}
	// No change, no write.
	same, _ := b.ChangeSettings(ctx, func(*Settings) {})
	if *same.Rev != 3 {
		t.Fatal(*same.Rev)
	}
}

func TestIDs(t *testing.T) {
	if id := NewHostID(); len(id) != 8 || strings.ToLower(id) != id {
		t.Fatal(id)
	}
	if id := NewUUID(); !isUUID(id) || strings.ToUpper(id) != id {
		t.Fatal(id)
	}
}
