package records

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"sort"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// People (#994, spec 736 data-model.md "User"): every client and every machine belongs
// to a user. The first person is the local owner: control.json's owner, an admin, whose
// sign-in is the control plane's key (codes). A person invited later signs in with the
// code they were sent until outside sign-in comes (#995).

const PeoplePrefix = "v1/people/"

// Roles and kinds, as Person.Role and Person.Kind say them.
const (
	RoleAdmin  = "admin"
	RoleMember = "member"
	KindPerson = "person"
	KindBot    = "bot"
)

// Sign-in providers this build makes.
const (
	// The local owner's: whoever holds the control plane's key (FR-002).
	ProviderLocal = "local"
	// An invite code redeemed (#994), until #995 brings Google, Apple and GitHub.
	ProviderCode = "code"
)

// SignIn is one way a person signs in: (provider, account) names one person only.
type SignIn struct {
	Provider string `json:"provider"`
	Account  string `json:"account"`
	Email    string `json:"email,omitempty"`
	Login    string `json:"login,omitempty"`
	Added    *Stamp `json:"added,omitempty"`
}

// Person is people/<id>.json: a user, a person or a bot. Today's record is {id, name};
// a role that is not there is admin, as the existing person is (FR-003).
type Person struct {
	ID        string
	Name      string
	Kind      string
	Role      string
	SignIns   []SignIn
	// A bot's group and spend caps (#1761); none for a person.
	Group     string
	Caps      *Caps
	Rev       int
	Removed   *bool
	RemovedAt *Stamp
	Extra     Extra
}

// Caps are a bot's or a group's spend caps (#1761, FR-033): none is no cap.
type Caps struct {
	DailyUSD *float64 `json:"dailyUSD,omitempty"`
}

type personJSON struct {
	ID        string   `json:"id"`
	Name      string   `json:"name"`
	Kind      string   `json:"kind,omitempty"`
	Role      string   `json:"role,omitempty"`
	SignIns   []SignIn `json:"signIns,omitempty"`
	Group     string   `json:"group,omitempty"`
	Caps      *Caps    `json:"caps,omitempty"`
	Rev       int      `json:"rev,omitempty"`
	Removed   *bool    `json:"removed,omitempty"`
	RemovedAt *Stamp   `json:"removedAt,omitempty"`
}

func (p Person) MarshalJSON() ([]byte, error) {
	return encodeKeeping(personJSON{p.ID, p.Name, p.Kind, p.Role, p.SignIns, p.Group, p.Caps, p.Rev, p.Removed, p.RemovedAt}, p.Extra)
}

func (p *Person) UnmarshalJSON(data []byte) error {
	var j personJSON
	extra, err := decodeKeeping(data, &j, "id", "name")
	if err != nil {
		return err
	}
	*p = Person{j.ID, j.Name, j.Kind, j.Role, j.SignIns, j.Group, j.Caps, j.Rev, j.Removed, j.RemovedAt, extra}
	return nil
}

// IsAdmin is a role of admin, or none. A bot never is.
func (p *Person) IsAdmin() bool { return p.Kind != KindBot && (p.Role == "" || p.Role == RoleAdmin) }

// IsBot says the user is a bot (#1761).
func (p *Person) IsBot() bool { return p.Kind == KindBot }

// RoleOrAdmin is the role, with none read as admin.
func (p *Person) RoleOrAdmin() string {
	if p.Role == "" {
		return RoleAdmin
	}
	return p.Role
}

// IsRemoved says the person was removed: kept, so their sign-ins stay refused.
func (p *Person) IsRemoved() bool { return p.Removed != nil && *p.Removed }

// HasSignIn says the person signs in with that provider and account.
func (p *Person) HasSignIn(provider, account string) bool {
	for _, s := range p.SignIns {
		if s.Provider == provider && s.Account == account {
			return true
		}
	}
	return false
}

// ControlKeyID is the local owner's account: the control plane's public key, hashed.
func ControlKeyID(public []byte) string {
	sum := sha256.Sum256(public)
	return hex.EncodeToString(sum[:8])
}

func (r *Records) loadPeople(ctx context.Context) error {
	listed, err := r.Store.List(ctx, PeoplePrefix)
	if err != nil {
		return err
	}
	r.mu.Lock()
	heldPeople := map[string]held[Person]{}
	for _, h := range r.people {
		heldPeople[PersonKey(h.record.ID)] = h
	}
	r.mu.Unlock()
	people := map[string]held[Person]{}
	for _, entry := range listed {
		if h, ok := heldPeople[entry.Key]; ok && h.etag == entry.ETag {
			people[h.record.ID] = h
			continue
		}
		object, ok := r.read(ctx, entry)
		if !ok || object == nil {
			if h, there := heldPeople[entry.Key]; there {
				people[h.record.ID] = h
			}
			continue
		}
		var p Person
		if err := p.UnmarshalJSON(object.Data); err != nil || PersonKey(p.ID) != entry.Key {
			r.noteUnreadable(entry.Key, object.ETag, "")
			continue
		}
		people[p.ID] = held[Person]{p, object.ETag}
	}
	r.mu.Lock()
	r.people = people
	r.mu.Unlock()
	return nil
}

// People is every person not removed: the local owner first, then by name.
func (r *Records) People() []Person {
	r.mu.Lock()
	defer r.mu.Unlock()
	owner := ""
	if o := r.owner(); o != nil {
		owner = *o
	}
	out := []Person{}
	for _, h := range r.people {
		if !h.record.IsRemoved() {
			out = append(out, h.record)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if (out[i].ID == owner) != (out[j].ID == owner) {
			return out[i].ID == owner
		}
		if out[i].Name != out[j].Name {
			return out[i].Name < out[j].Name
		}
		return out[i].ID < out[j].ID
	})
	return out
}

// Person is the person of that id, removed or not, or nil.
func (r *Records) Person(id string) *Person {
	r.mu.Lock()
	defer r.mu.Unlock()
	if h, ok := r.people[id]; ok {
		p := h.record
		return &p
	}
	return nil
}

// SavePerson makes a person, or changes one against the version read.
func (r *Records) SavePerson(ctx context.Context, p Person) error {
	r.writing.Lock()
	defer r.writing.Unlock()
	return r.savePerson(ctx, p)
}

func (r *Records) savePerson(ctx context.Context, p Person) error {
	r.mu.Lock()
	condition := store.Absent
	if h, ok := r.people[p.ID]; ok {
		p.Rev = h.record.Rev + 1
		condition = store.Matching(h.etag)
	} else if p.Rev == 0 {
		p.Rev = 1
	}
	r.mu.Unlock()
	kept, etag, err := write(ctx, r.Store, p, PersonKey(p.ID), condition)
	if err != nil {
		return err
	}
	r.mu.Lock()
	r.people[p.ID] = held[Person]{kept, etag}
	r.mu.Unlock()
	return nil
}

// ChangePeople changes people under the write lock, after reading them again, so a
// check across people (one admin at least, FR-006) holds against another copy's change:
// each changed person is written against the version read. change gets every person,
// removed ones too, and returns those to write; an error from it is returned as it is.
func (r *Records) ChangePeople(ctx context.Context, change func(map[string]Person) ([]Person, error)) error {
	r.writing.Lock()
	defer r.writing.Unlock()
	if err := r.loadPeople(ctx); err != nil {
		return err
	}
	r.mu.Lock()
	all := map[string]Person{}
	for id, h := range r.people {
		all[id] = h.record
	}
	r.mu.Unlock()
	changed, err := change(all)
	if err != nil {
		return err
	}
	for _, p := range changed {
		if err := r.savePerson(ctx, p); err != nil {
			return err
		}
	}
	return nil
}
