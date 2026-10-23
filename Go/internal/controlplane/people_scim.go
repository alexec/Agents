package controlplane

import (
	"cmp"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/audit"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/scim"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// SCIM users as people (#1002, spec 1002 slice 2a, FR-015 to FR-017): the SCIM id is the
// person's id. A person SCIM makes is provisioned until their first sign-in with the same
// provider, matched by the provider's match attribute (externalId, or userName) equal to
// the sign-in's account (D5, R5), and in no other way. active: false suspends them (D13);
// DELETE suspends them and asks an admin to remove them.

const (
	scimPrefix         = "v1/scim/"
	removeRequestsPath = "v1/requests/remove/"
	// lastNamesKept is how long a userName from before a rename still matches.
	lastNamesKept = 90 * 24 * time.Hour
	// cutOffAfter is how long a client is given to read control/cutOff before its sockets
	// close.
	cutOffAfter = 300 * time.Millisecond
)

const (
	personSuspended   = wire.FailurePersonSuspended
	managedByProvider = wire.FailureManagedByProvider
)

// scimNameKey is the index that makes one userName one person of a provider, at every
// copy: written only if absent (data-model.md).
func scimNameKey(provider, userName string) string {
	sum := sha256.Sum256([]byte(strings.ToLower(userName)))
	return scimPrefix + provider + "/names/" + hex.EncodeToString(sum[:]) + ".json"
}

func removeRequestKey(user string) string { return removeRequestsPath + user + ".json" }

// scimDirectory is scim.Directory over the people and groups.
type scimDirectory struct{ s *Service }

// scimProvider is a provider that is there and not removed, on or off.
func (si *signIns) scimProvider(ctx context.Context, id string) (*wire.OrgProvider, error) {
	kept, err := si.readOrgProvider(ctx, id)
	if err != nil {
		return nil, err
	}
	if kept == nil || kept.removed {
		return nil, fail(invalidParams, "There is no org provider %q.", id)
	}
	return &kept.p, nil
}

// matchOf is the provider's match attribute, externalId unless it says userName.
func matchOf(p *wire.OrgProvider) wire.SCIMMatch {
	if p != nil && p.Scim != nil && p.Scim.Match == wire.SCIMMatchUserName {
		return wire.SCIMMatchUserName
	}
	return wire.SCIMMatchExternalId
}

func matchValue(match wire.SCIMMatch, externalID, userName string) string {
	if match == wire.SCIMMatchUserName {
		return userName
	}
	return externalID
}

// scimPerson is a person of the provider that SCIM has, or nil: not removed, not deleted.
func scimPerson(p *records.Person, provider string) bool {
	return p != nil && !p.IsRemoved() && p.SCIM != nil && p.SCIM.Provider == provider && !p.SCIM.Deleted
}

func userOf(p records.Person) scim.User {
	sc := p.SCIM
	u := scim.User{ID: p.ID, ExternalID: sc.ExternalID, UserName: sc.UserName, DisplayName: sc.DisplayName, Active: sc.Active,
		Extra: sc.Extra}
	if sc.Name != nil {
		u.Name = &scim.Name{GivenName: deref(sc.Name.GivenName), FamilyName: deref(sc.Name.FamilyName), Formatted: deref(sc.Name.Formatted)}
	}
	for _, e := range sc.Emails {
		u.Emails = append(u.Emails, scim.Email{Value: e.Value, Type: deref(e.Type), Primary: deref(e.Primary)})
	}
	if sc.Created != nil {
		u.Created = sc.Created.Time
	}
	if sc.Changed != nil {
		u.Changed = sc.Changed.Time
	}
	return u
}

// scimPart is the person's scim part from a SCIM user.
func scimPart(provider string, u scim.User, created *records.Stamp) *records.PersonSCIM {
	now := records.Now()
	sc := &records.PersonSCIM{Provider: provider, ExternalID: u.ExternalID, UserName: u.UserName, DisplayName: u.DisplayName,
		Active: u.Active, Created: created, Changed: &now, Extra: u.Extra}
	if sc.Created == nil {
		sc.Created = &now
	}
	if u.Name != nil {
		sc.Name = &wire.SCIMName{GivenName: optional(u.Name.GivenName), FamilyName: optional(u.Name.FamilyName),
			Formatted: optional(u.Name.Formatted)}
	}
	for _, e := range u.Emails {
		email := wire.SCIMEmail{Value: e.Value, Type: optional(e.Type)}
		if e.Primary {
			email.Primary = new(true)
		}
		sc.Emails = append(sc.Emails, email)
	}
	return sc
}

// shownName is what People calls a SCIM user: displayName, the formatted name, given and
// family names, or the userName.
func shownName(u scim.User) string {
	name := u.DisplayName
	if name == "" && u.Name != nil {
		name = cmp.Or(u.Name.Formatted, strings.TrimSpace(u.Name.GivenName+" "+u.Name.FamilyName))
	}
	name = strings.TrimSpace(cmp.Or(name, u.UserName))
	if len([]rune(name)) > 80 {
		name = string([]rune(name)[:80])
	}
	return name
}

// scimActor is a SCIM write's actor (D16): the provider, and its token's id.
func (s *Service) scimActor(c scim.Caller) wire.AuditActor {
	actor := wire.AuditActor{User: "scim:" + c.Provider, Scim: &wire.AuditSCIM{Provider: c.Provider, Token: c.Token}}
	if p, err := s.signIns.scimProvider(context.Background(), c.Provider); err == nil {
		actor.UserName = optional(p.Name)
	}
	return actor
}

func (d scimDirectory) Users(ctx context.Context, provider string, keep func(scim.User) bool) ([]scim.User, error) {
	var out []scim.User
	d.s.records.EachPerson(func(p *records.Person) {
		if !p.IsRemoved() && scimPerson(p, provider) {
			if u := userOf(*p); keep(u) {
				out = append(out, u)
			}
		}
	})
	// By id, so that pages do not move as names change during a sync.
	slices.SortFunc(out, func(a, b scim.User) int { return strings.Compare(a.ID, b.ID) })
	return out, nil
}

func (d scimDirectory) User(ctx context.Context, provider, id string) (*scim.User, error) {
	p := d.s.records.Person(id)
	if !scimPerson(p, provider) {
		return nil, nil
	}
	u := userOf(*p)
	return &u, nil
}

// claimName writes the userName index for a person, or answers 409 when another person of
// the provider has it.
func (d scimDirectory) claimName(ctx context.Context, provider, userName, user string) error {
	key := scimNameKey(provider, userName)
	data, _ := records.Encode(map[string]string{"user": user})
	_, err := d.s.cfg.Store.Put(ctx, key, data, store.Absent)
	if err == nil {
		return nil
	}
	if !store.IsConflict(err) {
		return scim.Errorf(http.StatusServiceUnavailable, "", "The store could not be written. Try again.")
	}
	object, err := d.s.cfg.Store.Get(ctx, key)
	if err != nil || object == nil {
		return scim.Errorf(http.StatusServiceUnavailable, "", "The store could not be read. Try again.")
	}
	var held struct {
		User string `json:"user"`
	}
	_ = json.Unmarshal(object.Data, &held)
	if held.User == user {
		return nil
	}
	// One this copy has not read yet, perhaps just made at another copy, holds it too.
	if p := d.s.records.Person(held.User); p == nil || scimPerson(p, provider) && strings.EqualFold(p.SCIM.UserName, userName) {
		return scim.Uniqueness("Another user has the userName %q.", userName)
	}
	// Held by one deleted, removed or renamed since: it is this one's now.
	if _, err := d.s.cfg.Store.Put(ctx, key, data, store.Matching(object.ETag)); err != nil {
		return scim.Uniqueness("Another user has the userName %q.", userName)
	}
	return nil
}

func (d scimDirectory) dropName(ctx context.Context, provider, userName, user string) {
	key := scimNameKey(provider, userName)
	object, err := d.s.cfg.Store.Get(ctx, key)
	if err != nil || object == nil {
		return
	}
	var held struct {
		User string `json:"user"`
	}
	if json.Unmarshal(object.Data, &held) == nil && held.User == user {
		_ = d.s.cfg.Store.Delete(ctx, key)
	}
}

// personSignedInFirst is the person who signs in with that account, without reading every
// person again for each user a sync makes (#2430): this copy's, or else the one an org
// sign-in makes for it (personIDForSignIn), read by its key, since another copy may have
// made it a moment ago.
func (d scimDirectory) personSignedInFirst(ctx context.Context, provider, account string) *records.Person {
	if p := d.s.records.PersonWithSignIn(provider, account); p != nil {
		return p
	}
	p, err := d.s.records.ReadPerson(ctx, personIDForSignIn(provider, account))
	if err != nil || p == nil || !p.HasSignIn(provider, account) {
		return nil
	}
	return p
}

// CreateUser makes a provisioned person (US4 AS2), or links the SCIM user to the person
// who signed in first with the provider (Anyone the provider signs in), matched as a
// sign-in is (edge case "A SCIM POST for a user who signed in first").
func (d scimDirectory) CreateUser(ctx context.Context, c scim.Caller, u scim.User) (*scim.User, error) {
	p, err := d.s.signIns.scimProvider(ctx, c.Provider)
	if err != nil {
		return nil, scim.Errorf(http.StatusNotFound, "", "This provider is not here.")
	}
	match := matchOf(p)
	account := matchValue(match, u.ExternalID, u.UserName)
	var linked *records.Person
	if account != "" {
		if found := d.personSignedInFirst(ctx, c.Provider, account); found != nil && !found.IsRemoved() &&
			(found.SCIM == nil || found.SCIM.Deleted || found.SCIM.Provider != c.Provider) {
			linked = found
		}
	}
	id := records.NewPersonID()
	if linked != nil {
		id = linked.ID
	}
	if err := d.claimName(ctx, c.Provider, u.UserName, id); err != nil {
		return nil, err
	}
	var person records.Person
	if linked != nil {
		person = *linked
		person.SCIM = scimPart(c.Provider, u, nil)
		person.Name = shownName(u)
	} else {
		person = records.Person{ID: id, Name: shownName(u), Kind: records.KindPerson, Role: records.RoleMember,
			SCIM: scimPart(c.Provider, u, nil), Provisioned: true}
	}
	if err := d.s.records.SavePerson(ctx, person); err != nil {
		if linked == nil {
			d.dropName(ctx, c.Provider, u.UserName, id)
		}
		return nil, scim.Errorf(http.StatusServiceUnavailable, "", "The person could not be kept. Try again.")
	}
	actor := d.s.scimActor(c)
	what := "made " + person.Name + " (" + u.UserName + ")"
	if linked != nil {
		what = "linked " + person.Name + " (" + u.UserName + "), who signed in first"
	}
	d.s.auditAs(actor, "scim/user/create", what)
	if !u.Active {
		d.s.suspend(ctx, id, records.Suspension{By: "scim", Provider: c.Provider, At: records.Now(), Why: "made inactive"}, actor)
	}
	d.s.scimPeopleChanged(id, linked != nil)
	kept := d.s.records.Person(id)
	out := userOf(*kept)
	return &out, nil
}

// changePerson changes one person against the version this copy holds, and once more
// after reading every person again if another copy changed them first.
func (s *Service) changePerson(ctx context.Context, id string, change func(*records.Person) (bool, error)) error {
	if p := s.records.Person(id); p != nil {
		next := *p
		ok, err := change(&next)
		if err != nil || !ok {
			return err
		}
		if err := s.records.SavePerson(ctx, next); err == nil || !store.IsConflict(err) {
			return err
		}
	}
	return s.records.ChangePeople(ctx, func(all map[string]records.Person) ([]records.Person, error) {
		p, there := all[id]
		if !there {
			return nil, nil
		}
		ok, err := change(&p)
		if err != nil || !ok {
			return nil, err
		}
		return []records.Person{p}, nil
	})
}

// ReplaceUser is PUT, and PATCH once applied (US4 AS4 to AS6): the scim part and the name
// change; the sign-in does not. active turns suspension on or off.
func (d scimDirectory) ReplaceUser(ctx context.Context, c scim.Caller, u scim.User) (*scim.User, error) {
	before := d.s.records.Person(u.ID)
	if !scimPerson(before, c.Provider) {
		return nil, scim.Errorf(http.StatusNotFound, "", "No user %s here.", u.ID)
	}
	renamed := !strings.EqualFold(before.SCIM.UserName, u.UserName)
	if renamed {
		if err := d.claimName(ctx, c.Provider, u.UserName, u.ID); err != nil {
			return nil, err
		}
	}
	changes := userChanges(*before.SCIM, u)
	if changes == "" && before.Name == shownName(u) {
		// A sync sends every user again, mostly as they were: nothing is kept or told (#2424).
		out := userOf(*before)
		return &out, nil
	}
	err := d.s.changePerson(ctx, u.ID, func(p *records.Person) (bool, error) {
		if !scimPerson(p, c.Provider) {
			return false, scim.Errorf(http.StatusNotFound, "", "No user %s here.", u.ID)
		}
		now := time.Now()
		p.LastNames = slices.DeleteFunc(p.LastNames, func(l records.LastName) bool { return !now.Before(l.Until.Time) })
		if !strings.EqualFold(p.SCIM.UserName, u.UserName) {
			p.LastNames = append(p.LastNames, records.LastName{UserName: p.SCIM.UserName, Until: records.At(now.Add(lastNamesKept))})
		}
		p.SCIM = scimPart(c.Provider, u, p.SCIM.Created)
		p.Name = shownName(u)
		return true, nil
	})
	if err != nil {
		if renamed {
			d.dropName(ctx, c.Provider, u.UserName, u.ID)
		}
		if _, ok := err.(*scim.Error); ok {
			return nil, err
		}
		return nil, scim.Errorf(http.StatusServiceUnavailable, "", "The person could not be kept. Try again.")
	}
	if renamed {
		d.dropName(ctx, c.Provider, before.SCIM.UserName, u.ID)
	}
	actor := d.s.scimActor(c)
	if changes != "" {
		d.s.auditAs(actor, "scim/user/change", before.Name+": "+changes)
	}
	switch {
	case before.SCIM.Active && !u.Active:
		d.s.suspend(ctx, u.ID, records.Suspension{By: "scim", Provider: c.Provider, At: records.Now(), Why: "made inactive"}, actor)
	case !before.SCIM.Active && u.Active:
		d.s.unsuspend(ctx, u.ID, c.Provider, actor)
	}
	d.s.scimPeopleChanged(u.ID, false)
	out := userOf(*d.s.records.Person(u.ID))
	return &out, nil
}

// userChanges names the fields a SCIM write changed, for the audit.
func userChanges(before records.PersonSCIM, u scim.User) string {
	after := scimPart(before.Provider, u, before.Created)
	var changed []string
	same := func(a, b any) bool {
		x, _ := json.Marshal(a)
		y, _ := json.Marshal(b)
		return string(x) == string(y)
	}
	for _, f := range []struct {
		name string
		a, b any
	}{{"userName", before.UserName, after.UserName}, {"externalId", before.ExternalID, after.ExternalID},
		{"name", before.Name, after.Name}, {"displayName", before.DisplayName, after.DisplayName},
		{"emails", before.Emails, after.Emails}, {"active", before.Active, after.Active}, {"extensions", before.Extra, after.Extra}} {
		if !same(f.a, f.b) {
			changed = append(changed, f.name)
		}
	}
	return strings.Join(changed, ", ")
}

// DeleteUser suspends the person and asks an admin to remove them (D13, FR-017). To the
// provider the user is gone: a GET answers 404.
func (d scimDirectory) DeleteUser(ctx context.Context, c scim.Caller, id string) error {
	before := d.s.records.Person(id)
	if !scimPerson(before, c.Provider) {
		return scim.Errorf(http.StatusNotFound, "", "No user %s here.", id)
	}
	err := d.s.changePerson(ctx, id, func(p *records.Person) (bool, error) {
		if !scimPerson(p, c.Provider) {
			return false, nil
		}
		p.SCIM.Deleted, p.SCIM.Active = true, false
		return true, nil
	})
	if err != nil {
		return scim.Errorf(http.StatusServiceUnavailable, "", "The person could not be kept. Try again.")
	}
	d.dropName(ctx, c.Provider, before.SCIM.UserName, id)
	actor := d.s.scimActor(c)
	d.s.auditAs(actor, "scim/user/delete", before.Name+" ("+before.SCIM.UserName+"): suspended, and an admin asked to remove them")
	d.s.suspend(ctx, id, records.Suspension{By: "scim", Provider: c.Provider, At: records.Now(), Why: "deleted"}, actor)
	d.s.requestRemove(ctx, id, c.Provider, actor)
	d.s.scimPeopleChanged(id, false)
	return nil
}

// scimPeopleChanged tells admins here of a SCIM write. A person with no client and no
// machine changes nothing at the other copies or on any machine, so a first sync of
// thousands of people is not thousands of announcements; one who has is told everywhere.
func (s *Service) scimPeopleChanged(user string, everywhere bool) {
	if !everywhere {
		for _, c := range s.records.Clients() {
			if s.PersonOf(c.ID) == user {
				everywhere = true
				break
			}
		}
	}
	if !everywhere {
		for _, h := range s.records.Hosts() {
			if s.ownerOf(h.ID) == user {
				everywhere = true
				break
			}
		}
	}
	if everywhere {
		s.peopleChanged(user, false)
		return
	}
	change := wire.PeopleChanged{User: &user}
	for _, p := range s.records.People() {
		if p.IsAdmin() {
			s.router.TellPerson(p.ID, "control/peopleChanged", change)
		}
	}
}

// auditAs keeps an entry for something no client asked for: a SCIM write, a suspension.
func (s *Service) auditAs(actor wire.AuditActor, method, target string) {
	action, ok := audit.Action(method, false)
	if !ok {
		return
	}
	if len(target) > 300 {
		target = target[:300] + "…"
	}
	s.auditTo(actor, method, action, target)
}

// MARK: The match at first sign-in (FR-016)

// matchProvisioned finds the person SCIM made for an org sign-in, by the provider's match
// attribute equal to its account (or a userName from before a rename), and links the
// sign-in to them: no longer provisioned. Nil when SCIM is off or nobody matches.
func (si *signIns) matchProvisioned(ctx context.Context, provider, account, email string) (*records.Person, error) {
	p, err := si.scimProvider(ctx, provider)
	if err != nil || p.Scim == nil || !p.Scim.On || account == "" {
		return nil, nil
	}
	match := matchOf(p)
	var found string
	now := time.Now()
	stamp := records.At(now)
	err = si.s.records.ChangePeople(ctx, func(all map[string]records.Person) ([]records.Person, error) {
		for _, q := range all {
			if !scimPerson(&q, provider) {
				continue
			}
			hit := matchValue(match, q.SCIM.ExternalID, q.SCIM.UserName) == account
			if match == wire.SCIMMatchUserName && !hit {
				hit = strings.EqualFold(q.SCIM.UserName, account)
				for _, l := range q.LastNames {
					hit = hit || strings.EqualFold(l.UserName, account) && now.Before(l.Until.Time)
				}
			}
			if !hit {
				continue
			}
			found = q.ID
			if q.HasSignIn(provider, account) {
				return nil, nil
			}
			q.SignIns = append(q.SignIns, records.SignIn{Provider: provider, Account: account, Email: email, Added: &stamp})
			q.Provisioned = false
			return []records.Person{q}, nil
		}
		return nil, nil
	})
	if err != nil {
		return nil, fail(storeUnavailable, "The people could not be read: %v", err)
	}
	if found == "" {
		return nil, nil
	}
	si.s.log("person " + found + " signed in with " + provider + " for the first time, matched to the person SCIM made")
	si.s.peopleChanged(found, false)
	return si.s.records.Person(found), nil
}

// MARK: Suspension (D13, FR-017)

// suspended says a person's clients and machines are cut off. The local owner never is:
// their sign-in holds the control plane's key, and only their org sign-in is refused (D6).
func (s *Service) suspended(user string) bool {
	if user == s.localOwner() {
		return false
	}
	p := s.records.Person(user)
	return p != nil && p.IsSuspended()
}

// suspend marks a person suspended, then cuts them off here and at every other copy
// within 5 seconds: their clients are told control/cutOff and closed, their keys stop
// renewing, and each of their machines is told user/suspended.
func (s *Service) suspend(ctx context.Context, user string, why records.Suspension, actor wire.AuditActor) {
	changed := false
	err := s.changePerson(ctx, user, func(p *records.Person) (bool, error) {
		if p.IsSuspended() || p.IsRemoved() {
			return false, nil
		}
		p.Suspended, changed = &why, true
		return true, nil
	})
	if err != nil {
		s.log("could not suspend " + user + ": " + err.Error())
		return
	}
	if !changed {
		return
	}
	s.suspendedHere(user)
	if s.providers != nil {
		s.providers.StopFor(user, "suspension ("+why.Provider+")")
	}
	s.announce("personSuspended", user, "")
	s.auditAs(actor, "person/suspended", fmt.Sprintf("%s, by %s (%s)", cmp.Or(s.personName(user), user), why.Provider, why.Why))
	s.log("person " + user + " suspended by " + why.Provider + ": " + why.Why)
	s.peopleChanged(user, false)
}

// unsuspend ends a suspension the provider made: the person's clients pair again, and
// their machines are told user/suspended off.
func (s *Service) unsuspend(ctx context.Context, user, provider string, actor wire.AuditActor) {
	changed := false
	err := s.changePerson(ctx, user, func(p *records.Person) (bool, error) {
		if !p.IsSuspended() || p.Suspended.Provider != provider {
			return false, nil
		}
		p.Suspended, changed = nil, true
		return true, nil
	})
	if err != nil {
		s.log("could not end " + user + "'s suspension: " + err.Error())
		return
	}
	if !changed {
		return
	}
	_ = s.cfg.Store.Delete(ctx, removeRequestKey(user))
	s.suspendedHere(user)
	s.announce("personSuspended", user, "")
	s.auditAs(actor, "person/unsuspended", cmp.Or(s.personName(user), user)+", by "+provider)
	s.log("person " + user + " no longer suspended")
	s.peopleChanged(user, false)
}

// suspendedHere applies a person's suspension, or its end, to this copy's sessions and
// machines.
func (s *Service) suspendedHere(user string) {
	for _, host := range s.router.HostsHeldHere() {
		if s.ownerOf(host) == user {
			s.sendUserSuspended(host)
			// A suspended person's machine keeps no org route; they come back with the end.
			go s.sendOrgRoutes(host, true)
		}
	}
	if !s.suspended(user) {
		return
	}
	p := s.records.Person(user)
	s.router.TellPerson(user, wire.NotifyControlCutOff.Name, wire.ControlCutOff{Why: "suspended", Provider: optional(p.Suspended.Provider)})
	time.AfterFunc(cutOffAfter, func() { s.router.CutOffPerson(user) })
}

// sendUserSuspended tells a machine whether its person is suspended (FR-018). A machine
// that cannot hear it, whose person is suspended, is closed: its hello is refused.
func (s *Service) sendUserSuspended(host string) {
	user := s.ownerOf(host)
	p := s.records.Person(user)
	if p == nil {
		return
	}
	if !s.takesSuspension(host) {
		if s.suspended(user) {
			s.router.CloseLocal(host)
		}
		return
	}
	note := wire.UserSuspended{User: user, At: wire.DateOf(time.Now())}
	if s.suspended(user) {
		note.Provider, note.At = p.Suspended.Provider, wire.DateOf(p.Suspended.At.Time)
	} else {
		note.Off = new(true)
	}
	s.router.Tell(host, wire.NotifyUserSuspended.Name, note)
}

// takesSuspension says a machine said host.suspend/1.
func (s *Service) takesSuspension(host string) bool {
	h := s.records.Host(host)
	return h != nil && slices.Contains(hostCapabilities(*h), wire.CapHostSuspend1)
}

// refuseSuspendedHost is a machine's hello refused: its person is suspended and it cannot
// stop their work.
func (s *Service) refuseSuspendedHost(host string, capabilities []string) error {
	if !s.suspended(s.ownerOf(host)) || slices.Contains(capabilities, wire.CapHostSuspend1) {
		return nil
	}
	return fail(personSuspended, "This machine's person was suspended by their organisation, and this machine cannot stop their work. Update Agents on it.")
}

// MARK: Remove requests (D13, FR-017)

type removeRequest struct {
	User     string        `json:"user"`
	Provider string        `json:"provider"`
	At       records.Stamp `json:"at"`
}

// requestRemove asks admins to remove a person SCIM deleted: they confirm with
// people/remove, which shows what work is not pushed first.
func (s *Service) requestRemove(ctx context.Context, user, provider string, actor wire.AuditActor) {
	data, _ := records.Encode(removeRequest{User: user, Provider: provider, At: records.Now()})
	if _, err := s.cfg.Store.Put(ctx, removeRequestKey(user), data, store.Absent); err != nil && !store.IsConflict(err) {
		s.log("could not keep the Remove request for " + user + ": " + err.Error())
		return
	}
	name := cmp.Or(s.personName(user), user)
	providerName := provider
	if actor.UserName != nil {
		providerName = *actor.UserName
	}
	s.noticeAdmins(wire.ControlNotice{Kind: "removeRequested", User: &user,
		Words: providerName + " deleted " + name + ". " + name + " is suspended until an admin removes them in Console ▸ Requests."})
}

// removeRequests is people/removeRequests: oldest first.
func (s *Service) removeRequests(ctx context.Context) (wire.RemoveRequestList, error) {
	out := wire.RemoveRequestList{Requests: []wire.RemoveRequest{}}
	keys, err := s.cfg.Store.List(ctx, removeRequestsPath)
	if err != nil {
		return out, fail(storeUnavailable, "The requests could not be read: %v", err)
	}
	for _, k := range keys {
		object, err := s.cfg.Store.Get(ctx, k.Key)
		if err != nil || object == nil {
			continue
		}
		var r removeRequest
		if json.Unmarshal(object.Data, &r) != nil {
			continue
		}
		p := s.records.Person(r.User)
		if p == nil || p.IsRemoved() {
			_ = s.cfg.Store.Delete(ctx, k.Key)
			continue
		}
		out.Requests = append(out.Requests, wire.RemoveRequest{User: r.User, Name: p.Name, Provider: r.Provider, At: wire.DateOf(r.At.Time)})
	}
	slices.SortFunc(out.Requests, func(a, b wire.RemoveRequest) int { return a.At.Time().Compare(b.At.Time()) })
	return out, nil
}

// noticeAdmins tells every admin's sessions here, and at every copy, what no click caused.
func (s *Service) noticeAdmins(n wire.ControlNotice) {
	s.noticeAdminsHere(n)
	if s.mesh != nil {
		data, _ := json.Marshal(n)
		s.announce("notice", string(data), "")
	}
}

func (s *Service) noticeAdminsHere(n wire.ControlNotice) {
	told := map[string]bool{}
	for _, p := range s.records.People() {
		if p.IsAdmin() && !p.IsRemoved() {
			s.router.TellPerson(p.ID, wire.NotifyControlNotice.Name, n)
			told[p.ID] = true
		}
	}
	if !told[s.localOwner()] {
		s.router.TellPerson(s.localOwner(), wire.NotifyControlNotice.Name, n)
	}
}
