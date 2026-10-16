// Package records is ControlRecords.swift and the records of Grant.swift in Go: one object
// per client and per host, the settings, kept in a store with conditional writes against
// the version read, and forgetting written as a tombstone.
//
// Stored JSON is the Swift records' own (dates ISO 8601 with milliseconds, data base64,
// UUIDs upper case), so a Swift agents-control can read a store the Go one wrote.
package records

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/controlplane-go/internal/store"
)

const (
	ClientsPrefix = "v1/clients/"
	HostsPrefix   = "v1/hosts/"
	SettingsKey   = "v1/control.json"
)

func ClientKey(id string) string { return ClientsPrefix + strings.ToLower(id) + ".json" }
func HostKey(id string) string   { return HostsPrefix + id + ".json" }

// Stamp is a date as the stores write it: ISO 8601, UTC, milliseconds.
type Stamp struct{ time.Time }

const isoMillis = "2006-01-02T15:04:05.000Z07:00"

func Now() Stamp { return Stamp{time.Now().UTC().Truncate(time.Millisecond)} }

func (s Stamp) MarshalJSON() ([]byte, error) { return json.Marshal(s.UTC().Format(isoMillis)) }

func (s *Stamp) UnmarshalJSON(b []byte) error {
	var text string
	if err := json.Unmarshal(b, &text); err != nil {
		return err
	}
	t, err := time.Parse(time.RFC3339Nano, text)
	if err != nil {
		return fmt.Errorf("not an ISO 8601 date: %s", text)
	}
	s.Time = t
	return nil
}

// RefDate is a date as Swift's JSONEncoder writes it on the wire by default: seconds
// since 2001-01-01, a Double.
func RefDate(t time.Time) float64 {
	return float64(t.UnixNano()-978307200*int64(time.Second)) / 1e9
}

type ClientRecord struct {
	ID          string  `json:"id"`
	Name        string  `json:"name"`
	Kind        string  `json:"kind"`
	PublicKey   []byte  `json:"publicKey"`
	Grant       string  `json:"grant"`
	Paired      Stamp   `json:"paired"`
	LastSeen    *Stamp  `json:"lastSeen,omitempty"`
	MayNotify   *bool   `json:"mayNotify,omitempty"`
	Owner       *string `json:"owner,omitempty"`
	Rev         int     `json:"rev"`
	Forgotten   *bool   `json:"forgotten,omitempty"`
	ForgottenAt *Stamp  `json:"forgottenAt,omitempty"`
	KnownEpoch  *int    `json:"knownEpoch,omitempty"`
}

// IsDevice is ClientRecord.Kind.isDevice: a phone, an iPad, or a device of no kind said.
func (c *ClientRecord) IsDevice() bool { return c.Kind != "mac" && c.Kind != "browser" }

// Wire is the record as clients/list says it: Swift's default JSONEncoder, dates as Doubles.
func (c *ClientRecord) Wire() map[string]any {
	m := map[string]any{"id": c.ID, "name": c.Name, "kind": c.Kind, "publicKey": c.PublicKey,
		"grant": "operator", "paired": RefDate(c.Paired.Time), "rev": c.Rev}
	if c.LastSeen != nil {
		m["lastSeen"] = RefDate(c.LastSeen.Time)
	}
	if c.MayNotify != nil {
		m["mayNotify"] = *c.MayNotify
	}
	if c.Owner != nil {
		m["owner"] = *c.Owner
	}
	if c.KnownEpoch != nil {
		m["knownEpoch"] = *c.KnownEpoch
	}
	return m
}

type HostRecord struct {
	ID             string            `json:"id"`
	Name           string            `json:"name"`
	PublicKey      []byte            `json:"publicKey,omitempty"`
	Reach          json.RawMessage   `json:"reach"`
	Platform       string            `json:"platform"`
	Version        string            `json:"version"`
	Installed      bool              `json:"installed"`
	MachineID      *string           `json:"machineID,omitempty"`
	Relay          *bool             `json:"relay,omitempty"`
	SignInFrom     map[string]string `json:"signInFrom,omitempty"`
	Owner          *string           `json:"owner,omitempty"`
	Rev            int               `json:"rev"`
	Forgotten      *bool             `json:"forgotten,omitempty"`
	ForgottenAt    *Stamp            `json:"forgottenAt,omitempty"`
	KnownEpoch     *int              `json:"knownEpoch,omitempty"`
	DetectProjects *bool             `json:"detectProjects,omitempty"`
	Workspace      json.RawMessage   `json:"workspace,omitempty"`
}

var DialOut = json.RawMessage(`{"dialOut":{}}`)

type Settings struct {
	Name             string          `json:"name"`
	Port             int             `json:"port"`
	HomeHost         *string         `json:"homeHost,omitempty"`
	MachineID        string          `json:"machineID"`
	URL              *string         `json:"url,omitempty"`
	Pin              *string         `json:"pin,omitempty"`
	Endpoints        json.RawMessage `json:"endpoints,omitempty"`
	Epoch            *int            `json:"epoch,omitempty"`
	ControlKey       []byte          `json:"controlKey,omitempty"`
	Owner            *string         `json:"owner,omitempty"`
	Created          *Stamp          `json:"created,omitempty"`
	Rev              *int            `json:"rev,omitempty"`
	ProjectDetection json.RawMessage `json:"projectDetection,omitempty"`
	Channels         json.RawMessage `json:"channels,omitempty"`
}

func encode(v any) []byte {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		panic(err)
	}
	return b
}

func NewUUID() string {
	b := make([]byte, 16)
	rand.Read(b)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:]))
}

type held[T any] struct {
	rec  T
	etag string
}

// Records keeps what it has read, with each object's entity tag.
type Records struct {
	Store      store.Store
	mu         sync.Mutex
	clients    map[string]held[ClientRecord]
	hosts      map[string]held[HostRecord]
	settings   *held[Settings]
	tombstones map[string]string
	unreadable map[string]string
}

func New(s store.Store) *Records {
	return &Records{Store: s, clients: map[string]held[ClientRecord]{}, hosts: map[string]held[HostRecord]{},
		tombstones: map[string]string{}, unreadable: map[string]string{}}
}

// Load reads everything again; only objects whose tag changed are read (#174).
func (r *Records) Load(ctx context.Context) error {
	cl, err := r.Store.List(ctx, ClientsPrefix)
	if err != nil {
		return err
	}
	hl, err := r.Store.List(ctx, HostsPrefix)
	if err != nil {
		return err
	}
	r.mu.Lock()
	oldClients, oldHosts := r.clients, r.hosts
	tomb := r.tombstones
	r.mu.Unlock()
	byKeyC := map[string]held[ClientRecord]{}
	for _, h := range oldClients {
		byKeyC[ClientKey(h.rec.ID)] = h
	}
	byKeyH := map[string]held[HostRecord]{}
	for _, h := range oldHosts {
		byKeyH[HostKey(h.rec.ID)] = h
	}
	clients := map[string]held[ClientRecord]{}
	hosts := map[string]held[HostRecord]{}
	newTomb := map[string]string{}
	unread := map[string]string{}
	for _, e := range cl {
		if h, ok := byKeyC[e.Key]; ok && h.etag == e.ETag {
			clients[h.rec.ID] = h
			continue
		}
		if tomb[e.Key] == e.ETag {
			newTomb[e.Key] = e.ETag
			continue
		}
		o, err := r.Store.Get(ctx, e.Key)
		if err != nil || o == nil {
			if h, ok := byKeyC[e.Key]; ok && err != nil {
				clients[h.rec.ID] = h
			}
			if err != nil {
				unread[e.Key] = e.ETag
			}
			continue
		}
		var rec ClientRecord
		if json.Unmarshal(o.Data, &rec) != nil {
			unread[e.Key] = o.ETag
			continue
		}
		rec.ID = strings.ToUpper(rec.ID)
		if rec.Forgotten != nil && *rec.Forgotten {
			newTomb[e.Key] = o.ETag
			continue
		}
		clients[rec.ID] = held[ClientRecord]{rec, o.ETag}
	}
	for _, e := range hl {
		if h, ok := byKeyH[e.Key]; ok && h.etag == e.ETag {
			hosts[h.rec.ID] = h
			continue
		}
		if tomb[e.Key] == e.ETag {
			newTomb[e.Key] = e.ETag
			continue
		}
		o, err := r.Store.Get(ctx, e.Key)
		if err != nil || o == nil {
			if h, ok := byKeyH[e.Key]; ok && err != nil {
				hosts[h.rec.ID] = h
			}
			if err != nil {
				unread[e.Key] = e.ETag
			}
			continue
		}
		var rec HostRecord
		if json.Unmarshal(o.Data, &rec) != nil {
			unread[e.Key] = o.ETag
			continue
		}
		if rec.Forgotten != nil && *rec.Forgotten {
			newTomb[e.Key] = o.ETag
			continue
		}
		hosts[rec.ID] = held[HostRecord]{rec, o.ETag}
	}
	var settings *held[Settings]
	if o, err := r.Store.Get(ctx, SettingsKey); err == nil && o != nil {
		var s Settings
		if json.Unmarshal(o.Data, &s) == nil {
			settings = &held[Settings]{s, o.ETag}
		}
	}
	r.mu.Lock()
	r.clients, r.hosts, r.tombstones, r.unreadable = clients, hosts, newTomb, unread
	if settings != nil {
		r.settings = settings
	}
	r.mu.Unlock()
	return nil
}

func (r *Records) Clients() []ClientRecord {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]ClientRecord, 0, len(r.clients))
	for _, h := range r.clients {
		out = append(out, h.rec)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Paired.Before(out[j].Paired.Time) })
	return out
}

func (r *Records) Hosts() []HostRecord {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]HostRecord, 0, len(r.hosts))
	for _, h := range r.hosts {
		out = append(out, h.rec)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

func (r *Records) Client(id string) *ClientRecord {
	r.mu.Lock()
	defer r.mu.Unlock()
	if h, ok := r.clients[strings.ToUpper(id)]; ok {
		c := h.rec
		return &c
	}
	return nil
}

func (r *Records) Host(id string) *HostRecord {
	r.mu.Lock()
	defer r.mu.Unlock()
	if h, ok := r.hosts[id]; ok {
		c := h.rec
		return &c
	}
	return nil
}

// WasForgotten: its tombstone is still kept, so it is refused as forgotten, not unknown.
func (r *Records) WasForgotten(id string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	_, ok := r.tombstones[ClientKey(id)]
	return ok
}

func (r *Records) IsUnreadable(key string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	_, ok := r.unreadable[key]
	return ok
}

func (r *Records) Settings() *Settings {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.settings == nil {
		return nil
	}
	s := r.settings.rec
	return &s
}

// SettingsOrMake reads the settings, or makes them once; a copy that loses the race
// reads the winner's.
func (r *Records) SettingsOrMake(ctx context.Context, make func() Settings) (*Settings, error) {
	for attempt := 0; attempt < 3; attempt++ {
		if s := r.Settings(); s != nil {
			return s, nil
		}
		o, err := r.Store.Get(ctx, SettingsKey)
		if err != nil {
			return nil, err
		}
		if o != nil {
			var s Settings
			if err := json.Unmarshal(o.Data, &s); err != nil {
				return nil, fmt.Errorf("%s can't be read (%v); it is left as it is", SettingsKey, err)
			}
			r.mu.Lock()
			r.settings = &held[Settings]{s, o.ETag}
			r.mu.Unlock()
			return &s, nil
		}
		s := make()
		if s.Owner == nil {
			o := strings.ToLower(NewUUID())
			s.Owner = &o
		}
		now := Now()
		s.Created = &now
		one := 1
		s.Rev = &one
		tag, err := r.Store.Put(ctx, SettingsKey, encode(s), store.Absent)
		if store.IsConflict(err) {
			continue
		}
		if err != nil {
			return nil, err
		}
		r.mu.Lock()
		r.settings = &held[Settings]{s, tag}
		r.mu.Unlock()
		r.Store.Put(ctx, "v1/people/"+*s.Owner+".json", encode(map[string]string{"id": *s.Owner, "name": s.Name}), store.Absent)
		return &s, nil
	}
	return nil, &store.ConflictError{Key: SettingsKey}
}

// ChangeSettings changes them against the version read, again on what is there now a few
// times at most.
func (r *Records) ChangeSettings(ctx context.Context, change func(*Settings)) (*Settings, error) {
	for attempt := 0; attempt < 3; attempt++ {
		r.mu.Lock()
		h := r.settings
		r.mu.Unlock()
		if h == nil {
			return nil, &store.UnavailableError{Why: "there are no settings to change yet"}
		}
		s := h.rec
		before := string(encode(s))
		change(&s)
		if string(encode(s)) == before {
			return &s, nil
		}
		rev := 1
		if s.Rev != nil {
			rev = *s.Rev + 1
		}
		s.Rev = &rev
		tag, err := r.Store.Put(ctx, SettingsKey, encode(s), store.Matching(h.etag))
		if store.IsConflict(err) {
			o, err := r.Store.Get(ctx, SettingsKey)
			if err != nil || o == nil {
				return nil, &store.ConflictError{Key: SettingsKey}
			}
			var now Settings
			if json.Unmarshal(o.Data, &now) != nil {
				return nil, &store.ConflictError{Key: SettingsKey}
			}
			r.mu.Lock()
			r.settings = &held[Settings]{now, o.ETag}
			r.mu.Unlock()
			continue
		}
		if err != nil {
			return nil, err
		}
		r.mu.Lock()
		r.settings = &held[Settings]{s, tag}
		r.mu.Unlock()
		return &s, nil
	}
	return nil, &store.ConflictError{Key: SettingsKey}
}

func (r *Records) owner() *string {
	if s := r.settings; s != nil {
		return s.rec.Owner
	}
	return nil
}

// SaveClient creates a client, or updates it against the version read; a new one is
// written over the tombstone of the same id.
func (r *Records) SaveClient(ctx context.Context, c ClientRecord) error {
	r.mu.Lock()
	c.ID = strings.ToUpper(c.ID)
	c.Grant = "operator"
	if c.Owner == nil {
		c.Owner = r.owner()
	}
	key := ClientKey(c.ID)
	cond := store.Absent
	if h, ok := r.clients[c.ID]; ok {
		c.Rev = h.rec.Rev + 1
		cond = store.Matching(h.etag)
	} else {
		c.Rev = 1
		if t, ok := r.tombstones[key]; ok {
			cond = store.Matching(t)
		}
	}
	r.mu.Unlock()
	tag, err := r.Store.Put(ctx, key, encode(c), cond)
	if err != nil {
		return err
	}
	r.mu.Lock()
	r.clients[c.ID] = held[ClientRecord]{c, tag}
	delete(r.tombstones, key)
	r.mu.Unlock()
	return nil
}

// Forget writes a client's tombstone against the version read.
func (r *Records) Forget(ctx context.Context, id string) error {
	id = strings.ToUpper(id)
	if r.Client(id) == nil {
		if err := r.Load(ctx); err != nil {
			return err
		}
	}
	r.mu.Lock()
	h, ok := r.clients[id]
	r.mu.Unlock()
	if !ok {
		return nil
	}
	t := h.rec
	yes, now := true, Now()
	t.Forgotten, t.ForgottenAt = &yes, &now
	t.Rev++
	tag, err := r.Store.Put(ctx, ClientKey(id), encode(t), store.Matching(h.etag))
	if err != nil {
		return err
	}
	r.mu.Lock()
	r.tombstones[ClientKey(id)] = tag
	delete(r.clients, id)
	r.mu.Unlock()
	return nil
}

func (r *Records) SaveHost(ctx context.Context, h HostRecord) error {
	r.mu.Lock()
	if h.Owner == nil {
		h.Owner = r.owner()
	}
	if h.Reach == nil {
		h.Reach = DialOut
	}
	key := HostKey(h.ID)
	cond := store.Absent
	if old, ok := r.hosts[h.ID]; ok {
		a, b := old.rec, h
		a.Rev, b.Rev = 0, 0
		if string(encode(a)) == string(encode(b)) {
			r.mu.Unlock()
			return nil
		}
		h.Rev = old.rec.Rev + 1
		cond = store.Matching(old.etag)
	} else {
		h.Rev = 1
		if t, ok := r.tombstones[key]; ok {
			cond = store.Matching(t)
		}
	}
	r.mu.Unlock()
	tag, err := r.Store.Put(ctx, key, encode(h), cond)
	if err != nil {
		return err
	}
	r.mu.Lock()
	r.hosts[h.ID] = held[HostRecord]{h, tag}
	delete(r.tombstones, key)
	r.mu.Unlock()
	return nil
}

// RemoveHost writes a host's tombstone; false when there was no such host.
func (r *Records) RemoveHost(ctx context.Context, id string) (bool, error) {
	if r.Host(id) == nil {
		if err := r.Load(ctx); err != nil {
			return false, err
		}
	}
	r.mu.Lock()
	h, ok := r.hosts[id]
	r.mu.Unlock()
	if !ok {
		return false, nil
	}
	t := h.rec
	yes, now := true, Now()
	t.Forgotten, t.ForgottenAt = &yes, &now
	t.Rev++
	tag, err := r.Store.Put(ctx, HostKey(id), encode(t), store.Matching(h.etag))
	if err != nil {
		return false, err
	}
	r.mu.Lock()
	r.tombstones[HostKey(id)] = tag
	delete(r.hosts, id)
	r.mu.Unlock()
	return true, nil
}

// MakeHostID is HostID.make: eight lowercase letters and digits, never "mac".
func MakeHostID() string {
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	for {
		b := make([]byte, 8)
		rand.Read(b)
		for i := range b {
			b[i] = alphabet[int(b[i])%len(alphabet)]
		}
		if string(b) != "mac" {
			return string(b)
		}
	}
}
