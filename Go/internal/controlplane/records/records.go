// Package records is ControlRecords.swift: the control plane's records in a store (058,
// contracts/store.md, data-model.md), one object per client and per host, the
// settings, and the one person they belong to for now.
//
// It keeps what it has read, with each object's entity tag, and every change it makes is
// a conditional write against the version it read. Another copy's change first means a
// store.ConflictError, and nothing changed here either. Forgetting writes a tombstone,
// read as absent, because a store cannot be trusted to delete conditionally.
//
// The JSON is the Swift records' own (dates ISO 8601 with milliseconds, data base64,
// client ids in upper case), and fields this build does not know are written back as
// they were, so a Swift and a Go control plane can each read what the other wrote.
package records

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

const (
	ClientsPrefix  = "v1/clients/"
	MachinesPrefix = "v1/machines/"
	// OldMachinesPrefix is where builds before #2316 kept machines: moved to
	// MachinesPrefix when a store opens or is copied (#2662).
	OldMachinesPrefix = "v1/hosts/"
	SettingsKey    = "v1/control.json"
)

// ClientKey is where a client is kept: its UUID in lower case.
func ClientKey(id string) string { return ClientsPrefix + strings.ToLower(id) + ".json" }

// HostKey is where a host is kept.
func HostKey(id string) string { return MachinesPrefix + id + ".json" }

// PersonKey is where a person is kept.
func PersonKey(id string) string { return "v1/people/" + id + ".json" }

type held[T any] struct {
	record T
	etag   string
}

// Records is ControlRecords.
type Records struct {
	Store store.Store

	// writing makes one change at a time, as the Swift actor does: two changes from this
	// copy never write against the same tag, so only another copy's change conflicts.
	writing sync.Mutex

	mu       sync.Mutex
	clients  map[string]held[ClientRecord]
	hosts    map[string]held[MachineRecord]
	settings *held[Settings]
	// Every user, removed ones too (#994).
	people map[string]held[Person]
	// Every group, removed ones too (#1761).
	groups map[string]held[Group]
	// Tags of tombstones, so a refresh does not read them again and again.
	tombstones map[string]string
	// Keys listed whose object could not be read or decoded, by entity tag (#171). Such
	// a member is not known and not forgotten: it is refused as unavailable, and nobody
	// is closed over it. A record held from before keeps being used.
	unreadable map[string]string
	// Says a key could not be read, once per version of it.
	onUnreadable func(string)
}

func New(s store.Store) *Records {
	return &Records{Store: s, clients: map[string]held[ClientRecord]{}, hosts: map[string]held[MachineRecord]{},
		people: map[string]held[Person]{}, groups: map[string]held[Group]{}, tombstones: map[string]string{}, unreadable: map[string]string{}}
}

// OnUnreadable sets where an unreadable record is said, once per version (the log).
func (r *Records) OnUnreadable(say func(string)) {
	r.mu.Lock()
	r.onUnreadable = say
	r.mu.Unlock()
}

// Load reads everything from the store: at start-up, and as the backstop every 15 s
// (R4). Only objects whose tag changed are read again (#174).
func (r *Records) Load(ctx context.Context) error {
	r.writing.Lock()
	defer r.writing.Unlock()
	return r.load(ctx)
}

func (r *Records) load(ctx context.Context) error {
	listed, err := r.Store.List(ctx, ClientsPrefix)
	if err != nil {
		return err
	}
	listedHosts, err := r.Store.List(ctx, MachinesPrefix)
	if err != nil {
		return err
	}
	r.mu.Lock()
	heldClients := map[string]held[ClientRecord]{}
	for _, h := range r.clients {
		heldClients[ClientKey(h.record.ID)] = h
	}
	heldHosts := map[string]held[MachineRecord]{}
	for _, h := range r.hosts {
		heldHosts[HostKey(h.record.ID)] = h
	}
	r.mu.Unlock()

	clients := map[string]held[ClientRecord]{}
	for _, entry := range listed {
		var record ClientRecord
		etag, ok := r.readChanged(ctx, entry, heldClients[entry.Key].etag, &record)
		if !ok {
			if h, there := heldClients[entry.Key]; there {
				clients[h.record.ID] = h
			}
			continue
		}
		if etag == "" {
			continue
		}
		clients[record.ID] = held[ClientRecord]{record, etag}
	}
	hosts := map[string]held[MachineRecord]{}
	for _, entry := range listedHosts {
		var record MachineRecord
		etag, ok := r.readChanged(ctx, entry, heldHosts[entry.Key].etag, &record)
		if !ok {
			if h, there := heldHosts[entry.Key]; there {
				hosts[h.record.ID] = h
			}
			continue
		}
		if etag == "" {
			continue
		}
		hosts[record.ID] = held[MachineRecord]{record, etag}
	}

	present := map[string]bool{}
	for _, e := range append(listed, listedHosts...) {
		present[e.Key] = true
	}
	r.mu.Lock()
	r.clients, r.hosts = clients, hosts
	// A key no longer listed is no longer unreadable, and a tombstone the sweep deleted
	// is no longer one.
	for key := range r.unreadable {
		if !present[key] && key != SettingsKey {
			delete(r.unreadable, key)
		}
	}
	for key := range r.tombstones {
		if !present[key] {
			delete(r.tombstones, key)
		}
	}
	r.mu.Unlock()

	if err := r.loadPeople(ctx); err != nil {
		return err
	}
	if err := r.loadGroups(ctx); err != nil {
		return err
	}
	if object, ok := r.read(ctx, store.Key{Key: SettingsKey, ETag: "unreadable"}); ok && object != nil {
		var settings Settings
		if err := json.Unmarshal(object.Data, &settings); err != nil {
			r.noteUnreadable(SettingsKey, object.ETag, "")
		} else {
			r.mu.Lock()
			r.settings = &held[Settings]{settings, object.ETag}
			delete(r.unreadable, SettingsKey)
			r.mu.Unlock()
		}
	}
	return nil
}

// readChanged reads a listed record into into, unless what is held has its tag. It
// returns the tag read, "" for one gone or a tombstone, or false for one held as it was
// (unchanged, or unreadable now).
func (r *Records) readChanged(ctx context.Context, entry store.Key, heldTag string, into interface {
	UnmarshalJSON([]byte) error
}) (string, bool) {
	if heldTag != "" && heldTag == entry.ETag {
		return "", false
	}
	r.mu.Lock()
	tomb := r.tombstones[entry.Key] == entry.ETag
	r.mu.Unlock()
	if tomb {
		return "", true
	}
	object, ok := r.read(ctx, entry)
	if !ok {
		return "", false
	}
	if object == nil {
		return "", true
	}
	if err := into.UnmarshalJSON(object.Data); err != nil {
		r.noteUnreadable(entry.Key, object.ETag, "")
		return "", false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.unreadable, entry.Key)
	if forgotten(into) {
		r.tombstones[entry.Key] = object.ETag
		return "", true
	}
	delete(r.tombstones, entry.Key)
	return object.ETag, true
}

func forgotten(record any) bool {
	switch r := record.(type) {
	case *ClientRecord:
		return r.Forgotten != nil && *r.Forgotten
	case *MachineRecord:
		return r.Forgotten != nil && *r.Forgotten
	}
	return false
}

// read reads one listed object (#206): one file's EACCES or EIO is that member's, not a
// reason to stop reading the rest. One not readable is noted, and false.
func (r *Records) read(ctx context.Context, entry store.Key) (*store.Object, bool) {
	object, err := r.Store.Get(ctx, entry.Key)
	if err != nil {
		r.noteUnreadable(entry.Key, entry.ETag, err.Error())
		return nil, false
	}
	return object, true
}

func (r *Records) noteUnreadable(key, etag, why string) {
	r.mu.Lock()
	if r.unreadable[key] == etag {
		r.mu.Unlock()
		return
	}
	r.unreadable[key] = etag
	say := r.onUnreadable
	r.mu.Unlock()
	if say != nil {
		because := ""
		if why != "" {
			because = " (" + why + ")"
		}
		say(fmt.Sprintf("store: %s could not be read%s; it is left as it is, and its member is refused as unavailable rather than forgotten", key, because))
	}
}

// ClientUnreadable says a client is listed and its record could not be read: neither
// known nor forgotten (#171).
func (r *Records) ClientUnreadable(id string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	_, ok := r.unreadable[ClientKey(id)]
	return ok
}

// HostUnreadable is ClientUnreadable for a host.
func (r *Records) HostUnreadable(id string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	_, ok := r.unreadable[HostKey(id)]
	return ok
}

// TombstoneKeys is the key of every tombstone read, for the sweep (#174).
func (r *Records) TombstoneKeys() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]string, 0, len(r.tombstones))
	for key := range r.tombstones {
		out = append(out, key)
	}
	sort.Strings(out)
	return out
}

// Clients is every client, the first paired first.
func (r *Records) Clients() []ClientRecord {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]ClientRecord, 0, len(r.clients))
	for _, h := range r.clients {
		out = append(out, h.record)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Paired.Before(out[j].Paired.Time) })
	return out
}

// Hosts is every host, by id.
func (r *Records) Hosts() []MachineRecord {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]MachineRecord, 0, len(r.hosts))
	for _, h := range r.hosts {
		out = append(out, h.record)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// Client is the client of that id, or nil.
func (r *Records) Client(id string) *ClientRecord {
	r.mu.Lock()
	defer r.mu.Unlock()
	if h, ok := r.clients[strings.ToUpper(id)]; ok {
		c := h.record
		return &c
	}
	return nil
}

// WasForgotten says a client was forgotten and its tombstone is still kept (seven days):
// refused as forgotten, not unknown.
func (r *Records) WasForgotten(id string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	_, ok := r.tombstones[ClientKey(id)]
	return ok
}

// Host is the host of that id, or nil.
func (r *Records) Host(id string) *MachineRecord {
	r.mu.Lock()
	defer r.mu.Unlock()
	if h, ok := r.hosts[id]; ok {
		c := h.record
		return &c
	}
	return nil
}

// Settings are the settings read, or nil.
func (r *Records) Settings() *Settings {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.settings == nil {
		return nil
	}
	s := r.settings.record
	return &s
}

// SettingsOrMake is the settings, made once if there are none. Two copies starting on
// an empty store both try; the one that loses reads the winner's.
//
// Settings that are there and cannot be read are never made afresh over: they hold the
// owner and the key every member was paired against. Start-up stops and says so (#171).
func (r *Records) SettingsOrMake(ctx context.Context, makeSettings func() Settings) (*Settings, error) {
	r.writing.Lock()
	defer r.writing.Unlock()
	for attempt := 1; ; attempt++ {
		if s := r.Settings(); s != nil {
			return s, nil
		}
		object, err := r.Store.Get(ctx, SettingsKey)
		if err != nil {
			return nil, err
		}
		if object != nil {
			var s Settings
			if err := json.Unmarshal(object.Data, &s); err != nil {
				return nil, store.Unavailable("%s can't be read (%v); it is left as it is. Restore it from a backup, "+
					"or move it aside to start a new control plane and pair everything again", SettingsKey, err)
			}
			r.mu.Lock()
			r.settings = &held[Settings]{s, object.ETag}
			r.mu.Unlock()
			return &s, nil
		}
		made := makeSettings()
		if made.Owner == nil {
			owner := NewPersonID()
			made.Owner = &owner
		}
		if made.Created == nil {
			now := Now()
			made.Created = &now
		}
		one := 1
		made.Rev = &one
		kept, etag, err := write(ctx, r.Store, made, SettingsKey, store.Absent)
		if store.IsConflict(err) && attempt < 3 {
			continue
		}
		if err != nil {
			return nil, err
		}
		r.mu.Lock()
		r.settings = &held[Settings]{kept, etag}
		r.mu.Unlock()
		r.savePerson(ctx, r.localOwner(kept))
		return &kept, nil
	}
}

// ChangeSettings changes the settings against the version read. Another copy on the
// same store may have written them since (it writes its own address when it starts,
// T128): the change is made again on what is there now, a few times at most.
func (r *Records) ChangeSettings(ctx context.Context, change func(*Settings)) (*Settings, error) {
	r.writing.Lock()
	defer r.writing.Unlock()
	for attempt := 1; attempt <= 3; attempt++ {
		r.mu.Lock()
		h := r.settings
		r.mu.Unlock()
		if h == nil {
			return nil, store.Unavailable("there are no settings to change yet")
		}
		s := clone(h.record)
		change(&s)
		if same(s, h.record) {
			return &s, nil
		}
		rev := 1
		if s.Rev != nil {
			rev = *s.Rev + 1
		}
		s.Rev = &rev
		kept, etag, err := write(ctx, r.Store, s, SettingsKey, store.Matching(h.etag))
		if store.IsConflict(err) && attempt < 3 {
			object, err := r.Store.Get(ctx, SettingsKey)
			var now Settings
			if err != nil || object == nil || json.Unmarshal(object.Data, &now) != nil {
				return nil, &store.ConflictError{Key: SettingsKey}
			}
			r.mu.Lock()
			r.settings = &held[Settings]{now, object.ETag}
			r.mu.Unlock()
			continue
		}
		if err != nil {
			return nil, err
		}
		r.mu.Lock()
		r.settings = &held[Settings]{kept, etag}
		r.mu.Unlock()
		return &kept, nil
	}
	return nil, &store.ConflictError{Key: SettingsKey}
}

// localOwner is the first person, as made with new settings or by the migration
// (FR-002, FR-003): the admin, who signs in with the control plane's key.
func (r *Records) localOwner(s Settings) Person {
	now := Now()
	return Person{ID: *s.Owner, Name: s.Name, Kind: KindPerson, Role: RoleAdmin,
		SignIns: []SignIn{{Provider: ProviderLocal, Account: ControlKeyID(s.ControlKey), Added: &now}}}
}

// Migrate is the first start with people (#994, FR-003): the existing person becomes the
// local owner and the admin, and every client and host without an owner gets that
// person. Only fields are added; no key changes. It is safe to run on every start.
func (r *Records) Migrate(ctx context.Context) error {
	s := r.Settings()
	if s == nil || s.Owner == nil {
		return nil
	}
	r.writing.Lock()
	r.mu.Lock()
	h, known := r.people[*s.Owner]
	r.mu.Unlock()
	var err error
	if !known {
		err = r.savePerson(ctx, r.localOwner(*s))
	} else if p := h.record; p.Kind == "" || p.Role == "" || !p.HasSignIn(ProviderLocal, ControlKeyID(s.ControlKey)) {
		owner := r.localOwner(*s)
		if p.Kind == "" {
			p.Kind = KindPerson
		}
		if p.Role == "" {
			p.Role = RoleAdmin
		}
		if !p.HasSignIn(ProviderLocal, ControlKeyID(s.ControlKey)) {
			p.SignIns = append(p.SignIns, owner.SignIns[0])
		}
		err = r.savePerson(ctx, p)
	}
	r.writing.Unlock()
	if err != nil {
		return err
	}
	for _, c := range r.Clients() {
		if c.Owner == nil || *c.Owner == "" {
			if err := r.ChangeClient(ctx, c.ID, func(c *ClientRecord) bool { c.Owner = s.Owner; return true }); err != nil {
				return err
			}
		}
	}
	for _, h := range r.Hosts() {
		if h.Owner == nil || *h.Owner == "" {
			h.Owner = s.Owner
			if err := r.SaveHost(ctx, h); err != nil {
				return err
			}
		}
	}
	return nil
}

func (r *Records) owner() *string {
	if r.settings != nil {
		return r.settings.record.Owner
	}
	return nil
}

// overTombstone is where a record is new: an empty key, or the tombstone left when the
// same id was forgotten. A Remote keeps its id, so a device forgotten and paired again
// is written over its tombstone.
func overTombstone(etag string, ok bool) store.Condition {
	if ok {
		return store.Matching(etag)
	}
	return store.Absent
}

// SaveClient saves a client that paired, or one seen again: created if new, else
// updated against the version read.
func (r *Records) SaveClient(ctx context.Context, c ClientRecord) error {
	r.writing.Lock()
	defer r.writing.Unlock()
	r.mu.Lock()
	c.ID = strings.ToUpper(c.ID)
	if c.Owner == nil {
		c.Owner = r.owner()
	}
	key := ClientKey(c.ID)
	var condition store.Condition
	if h, ok := r.clients[c.ID]; ok {
		c.Rev = h.record.Rev + 1
		condition = store.Matching(h.etag)
	} else {
		c.Rev = 1
		etag, ok := r.tombstones[key]
		condition = overTombstone(etag, ok)
	}
	r.mu.Unlock()
	kept, etag, err := write(ctx, r.Store, c, key, condition)
	if err != nil {
		return err
	}
	r.mu.Lock()
	r.clients[c.ID] = held[ClientRecord]{kept, etag}
	delete(r.tombstones, key)
	r.mu.Unlock()
	return nil
}

// UpdateClient saves a change to a client already known: its last sight, its name, the
// endpoints it holds. One forgotten since it was read stays forgotten (#1229): the
// change is let go rather than written over its tombstone, which SaveClient would do.
func (r *Records) UpdateClient(ctx context.Context, c ClientRecord) error {
	r.writing.Lock()
	defer r.writing.Unlock()
	r.mu.Lock()
	c.ID = strings.ToUpper(c.ID)
	h, ok := r.clients[c.ID]
	r.mu.Unlock()
	if !ok {
		return nil
	}
	if c.Owner == nil {
		c.Owner = h.record.Owner
	}
	c.Rev = h.record.Rev + 1
	key := ClientKey(c.ID)
	kept, etag, err := write(ctx, r.Store, c, key, store.Matching(h.etag))
	if err != nil {
		return err
	}
	r.mu.Lock()
	r.clients[c.ID] = held[ClientRecord]{kept, etag}
	r.mu.Unlock()
	return nil
}

// ChangeClient changes a client already known on the copy held now, read and written
// under the write lock: a change made since the caller looked is kept. UpdateClient of
// a copy read before it would write over it, as a connect noting its endpoints in the
// background wrote over a device's kind and switch (#1505). change says whether there
// is anything to write. Nothing happens for a client not known.
func (r *Records) ChangeClient(ctx context.Context, id string, change func(*ClientRecord) bool) error {
	r.writing.Lock()
	defer r.writing.Unlock()
	id = strings.ToUpper(id)
	r.mu.Lock()
	h, ok := r.clients[id]
	r.mu.Unlock()
	if !ok {
		return nil
	}
	c := h.record
	if !change(&c) {
		return nil
	}
	c.ID = id
	c.Rev = h.record.Rev + 1
	kept, etag, err := write(ctx, r.Store, c, ClientKey(id), store.Matching(h.etag))
	if err != nil {
		return err
	}
	r.mu.Lock()
	r.clients[id] = held[ClientRecord]{kept, etag}
	r.mu.Unlock()
	return nil
}

// ForgetClient is clients/forget: a tombstone against the version read. Nothing happens
// for a client that is not known. The last client may go too (#111).
func (r *Records) ForgetClient(ctx context.Context, id string) error {
	r.writing.Lock()
	defer r.writing.Unlock()
	id = strings.ToUpper(id)
	if r.Client(id) == nil {
		if err := r.load(ctx); err != nil {
			return err
		}
	}
	// Another copy may have noted the client connecting since it was read: a forget means
	// the same whatever changed, so it is read again and tried once more.
	var etag string
	for attempt := 1; ; attempt++ {
		r.mu.Lock()
		h, ok := r.clients[id]
		r.mu.Unlock()
		if !ok {
			return nil
		}
		tombstone := h.record
		yes, now := true, Now()
		tombstone.Forgotten, tombstone.ForgottenAt = &yes, &now
		tombstone.Rev++
		var err error
		_, etag, err = write(ctx, r.Store, tombstone, ClientKey(id), store.Matching(h.etag))
		if store.IsConflict(err) && attempt < 2 {
			if err := r.load(ctx); err != nil {
				return err
			}
			continue
		}
		if err != nil {
			return err
		}
		break
	}
	r.mu.Lock()
	r.tombstones[ClientKey(id)] = etag
	delete(r.clients, id)
	r.mu.Unlock()
	return nil
}

// SaveHost saves a host: created if new, else updated against the version read, and
// not written at all if nothing but its revision would change.
func (r *Records) SaveHost(ctx context.Context, h MachineRecord) error {
	r.writing.Lock()
	defer r.writing.Unlock()
	r.mu.Lock()
	if h.Owner == nil {
		h.Owner = r.owner()
	}
	key := HostKey(h.ID)
	var condition store.Condition
	if old, ok := r.hosts[h.ID]; ok {
		a, b := old.record, h
		a.Rev, b.Rev = 0, 0
		if same(a, b) {
			r.mu.Unlock()
			return nil
		}
		h.Rev = old.record.Rev + 1
		condition = store.Matching(old.etag)
	} else {
		h.Rev = 1
		etag, ok := r.tombstones[key]
		condition = overTombstone(etag, ok)
	}
	r.mu.Unlock()
	kept, etag, err := write(ctx, r.Store, h, key, condition)
	if err != nil {
		return err
	}
	r.mu.Lock()
	r.hosts[h.ID] = held[MachineRecord]{kept, etag}
	delete(r.tombstones, key)
	r.mu.Unlock()
	return nil
}

// ChangeHost changes a host already known on the copy held now, read and written under
// the write lock, as ChangeClient does: a change made since the caller looked (a hello
// and a connect noting its epoch at once) is kept. change says whether there is anything
// to write. Nothing happens for a host not known.
func (r *Records) ChangeHost(ctx context.Context, id string, change func(*MachineRecord) bool) error {
	r.writing.Lock()
	defer r.writing.Unlock()
	r.mu.Lock()
	h, ok := r.hosts[id]
	r.mu.Unlock()
	if !ok {
		return nil
	}
	c := h.record
	if !change(&c) {
		return nil
	}
	a, b := h.record, c
	a.Rev, b.Rev = 0, 0
	if same(a, b) {
		return nil
	}
	c.ID = id
	c.Rev = h.record.Rev + 1
	kept, etag, err := write(ctx, r.Store, c, HostKey(id), store.Matching(h.etag))
	if err != nil {
		return err
	}
	r.mu.Lock()
	r.hosts[id] = held[MachineRecord]{kept, etag}
	r.mu.Unlock()
	return nil
}

// ErrHostTaken is AddHost's refusal: a host of that id is already kept, here or at
// another copy (#1996).
var ErrHostTaken = errors.New("a host of that id is already enrolled")

// AddHost saves a host that has just enrolled, only if no host has its id: one write
// that never replaces another machine's record or key, at this copy or another (#1996).
// It is ErrHostTaken otherwise.
func (r *Records) AddHost(ctx context.Context, h MachineRecord) error {
	r.writing.Lock()
	defer r.writing.Unlock()
	r.mu.Lock()
	if h.Owner == nil {
		h.Owner = r.owner()
	}
	key := HostKey(h.ID)
	if _, ok := r.hosts[h.ID]; ok {
		r.mu.Unlock()
		return ErrHostTaken
	}
	h.Rev = 1
	etag, ok := r.tombstones[key]
	r.mu.Unlock()
	kept, etag, err := write(ctx, r.Store, h, key, overTombstone(etag, ok))
	if store.IsConflict(err) {
		return ErrHostTaken
	}
	if err != nil {
		return err
	}
	r.mu.Lock()
	r.hosts[h.ID] = held[MachineRecord]{kept, etag}
	delete(r.tombstones, key)
	r.mu.Unlock()
	return nil
}

// RemoveHost is hosts/remove: a tombstone. It says whether there was such a host.
func (r *Records) RemoveHost(ctx context.Context, id string) (bool, error) {
	r.writing.Lock()
	defer r.writing.Unlock()
	if r.Host(id) == nil {
		if err := r.load(ctx); err != nil {
			return false, err
		}
	}
	// Another copy may have noted the host's hello or epoch since it was read (it is held
	// there): a removal means the same whatever changed, so it is read again and tried once
	// more, as a forget is (#1763).
	var etag string
	for attempt := 1; ; attempt++ {
		r.mu.Lock()
		h, ok := r.hosts[id]
		r.mu.Unlock()
		if !ok {
			return false, nil
		}
		tombstone := h.record
		yes, now := true, Now()
		tombstone.Forgotten, tombstone.ForgottenAt = &yes, &now
		tombstone.Rev++
		var err error
		_, etag, err = write(ctx, r.Store, tombstone, HostKey(id), store.Matching(h.etag))
		if store.IsConflict(err) && attempt < 2 {
			if err := r.load(ctx); err != nil {
				return false, err
			}
			continue
		}
		if err != nil {
			return false, err
		}
		break
	}
	r.mu.Lock()
	r.tombstones[HostKey(id)] = etag
	delete(r.hosts, id)
	r.mu.Unlock()
	return true, nil
}

// write writes a record, and returns it as the store now has it: dates to the
// millisecond, as every other copy will read it, so two copies compare equal.
func write[T any](ctx context.Context, s store.Store, record T, key string, when store.Condition) (T, string, error) {
	var kept T
	data, err := Encode(record)
	if err != nil {
		return kept, "", err
	}
	etag, err := s.Put(ctx, key, data, when)
	if err != nil {
		return kept, "", err
	}
	if err := json.Unmarshal(data, &kept); err != nil {
		return kept, "", err
	}
	return kept, etag, nil
}

func same(a, b any) bool {
	x, err1 := Encode(a)
	y, err2 := Encode(b)
	return err1 == nil && err2 == nil && bytes.Equal(x, y)
}

func clone(s Settings) Settings {
	var c Settings
	data, _ := json.Marshal(s)
	json.Unmarshal(data, &c)
	return c
}
