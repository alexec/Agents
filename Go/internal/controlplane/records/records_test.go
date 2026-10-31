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
	r.SaveHost(ctx, MachineRecord{ID: "box", Name: "Box", Platform: "linux"})
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
	r.SaveHost(ctx, MachineRecord{ID: "box", Name: "Box"})
	if gone, _ := r.RemoveHost(ctx, "box"); !gone {
		t.Fatal("not removed")
	}
	if gone, _ := r.RemoveHost(ctx, "box"); gone {
		t.Fatal("removed twice")
	}
}

// #1229: a change to a client read before it was forgotten, saved after, leaves it
// forgotten: a connect noting its endpoints does not bring it back.
func TestAForgottenClientStaysForgotten(t *testing.T) {
	s := store.NewMemory()
	r := New(s)
	id := NewUUID()
	r.SaveClient(ctx, ClientRecord{ID: id, Name: "Phone", Kind: KindIPhone, PublicKey: []byte{4}, Paired: Now()})
	read := r.Client(id)
	epoch := 0
	read.KnownEpoch = &epoch
	if err := r.ForgetClient(ctx, id); err != nil {
		t.Fatal(err)
	}
	if err := r.UpdateClient(ctx, *read); err != nil {
		t.Fatal(err)
	}
	other := New(s)
	other.Load(ctx)
	if r.Client(id) != nil || !r.WasForgotten(id) || other.Client(id) != nil || !other.WasForgotten(id) {
		t.Fatal("brought back")
	}
	// A known one is changed.
	id2 := NewUUID()
	r.SaveClient(ctx, ClientRecord{ID: id2, Name: "Pad", Kind: KindIPhone, PublicKey: []byte{5}, Paired: Now()})
	c := r.Client(id2)
	c.Name = "iPad"
	if err := r.UpdateClient(ctx, *c); err != nil || r.Client(id2).Name != "iPad" || r.Client(id2).Rev != 2 {
		t.Fatalf("%v %+v", err, r.Client(id2))
	}
}

// #1505: a change on the copy held keeps what was written since the caller looked, as
// a background write of a copy read before does not.
func TestAChangeKeepsWhatWasWrittenSince(t *testing.T) {
	r := New(store.NewMemory())
	id := NewUUID()
	r.SaveClient(ctx, ClientRecord{ID: id, Name: "Phone", Kind: KindUnknown, PublicKey: []byte{4}, Paired: Now()})
	yes := true
	var wg sync.WaitGroup
	for n := range 20 {
		wg.Add(2)
		go func() {
			defer wg.Done()
			r.ChangeClient(ctx, id, func(c *ClientRecord) bool {
				epoch := n
				c.KnownEpoch = &epoch
				return true
			})
		}()
		go func() {
			defer wg.Done()
			if n == 10 {
				r.ChangeClient(ctx, id, func(c *ClientRecord) bool {
					c.Kind, c.MayNotify = KindIPhone, &yes
					return true
				})
			}
		}()
	}
	wg.Wait()
	if c := r.Client(id); c.Kind != KindIPhone || c.MayNotify == nil || c.KnownEpoch == nil || c.Rev != 22 {
		t.Fatalf("%+v", c)
	}
	if err := r.ChangeClient(ctx, NewUUID(), func(*ClientRecord) bool { t.Fatal("changed an unknown client"); return true }); err != nil {
		t.Fatal(err)
	}
	unchanged := r.Client(id).Rev
	r.ChangeClient(ctx, id, func(*ClientRecord) bool { return false })
	if r.Client(id).Rev != unchanged {
		t.Fatal("wrote nothing")
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

// Changes from one copy never conflict with each other, as the Swift actor's do not:
// only another copy's change does.
func TestChangesHereDoNotConflictWithEachOther(t *testing.T) {
	r := New(store.NewMemory())
	id := NewUUID()
	r.SaveClient(ctx, ClientRecord{ID: id, Name: "Phone", Kind: KindIPhone, PublicKey: []byte{4}, Paired: Now()})
	var wg sync.WaitGroup
	errs := make(chan error, 40)
	for n := range 20 {
		wg.Add(2)
		go func() {
			defer wg.Done()
			c := r.Client(id)
			if c == nil {
				return
			}
			epoch := n
			c.KnownEpoch = &epoch
			errs <- r.SaveClient(ctx, *c)
		}()
		go func() {
			defer wg.Done()
			errs <- r.Load(ctx)
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if err := r.ForgetClient(ctx, id); err != nil {
		t.Fatal(err)
	}
}

// FR-003 (T007): the first start with people makes a v0.7 store's one person the local
// owner and the admin, and gives every client and host without one that owner. It only
// adds fields: what it does not know is kept, and no key moves.
func TestMigrationMakesTheLocalOwner(t *testing.T) {
	ctx := context.Background()
	s := store.NewMemory()
	owner := "0f8fad5b-d9cb-469f-a165-70867728950e"
	put := func(key, text string) {
		if _, err := s.Put(ctx, key, []byte(text), store.Absent); err != nil {
			t.Fatal(err)
		}
	}
	put(SettingsKey, `{"name":"Alex's control plane","port":8790,"machineID":"M1","owner":"`+owner+`","controlKey":"AQID"}`)
	put(PersonKey(owner), `{"id":"`+owner+`","name":"Alex's control plane","later":true}`)
	put(ClientKey("E621E1F8-C36C-495A-93FC-0C247A3E6E5F"), `{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","name":"Mac","kind":"mac","publicKey":"AQID","grant":"operator","paired":"2026-10-01T00:00:00.000Z","rev":1}`)
	put(HostKey("abcd1234"), `{"id":"abcd1234","name":"box","reach":{"dialOut":{}},"platform":"Linux","version":"1","installed":false,"rev":1}`)
	r := New(s)
	if err := r.Load(ctx); err != nil {
		t.Fatal(err)
	}
	if err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	if err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	again := New(s)
	if err := again.Load(ctx); err != nil {
		t.Fatal(err)
	}
	p := again.Person(owner)
	if p == nil || p.Role != RoleAdmin || p.Kind != KindPerson || !p.HasSignIn(ProviderLocal, ControlKeyID([]byte{1, 2, 3})) ||
		len(p.SignIns) != 1 || string(p.Extra["later"]) != "true" || p.Rev != 1 {
		t.Fatalf("%+v", p)
	}
	if c := again.Client("E621E1F8-C36C-495A-93FC-0C247A3E6E5F"); c == nil || c.Owner == nil || *c.Owner != owner {
		t.Fatalf("%+v", c)
	}
	if h := again.Host("abcd1234"); h == nil || h.Owner == nil || *h.Owner != owner {
		t.Fatalf("%+v", h)
	}
	if people := again.People(); len(people) != 1 {
		t.Fatalf("%+v", people)
	}
}
