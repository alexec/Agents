package controlplane

import (
	"context"
	"encoding/json"
	"fmt"
	"maps"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/controlplane/usersettings"
	"github.com/alexec/agents/Go/wire"
)

// Sealing again (#3397, specs/3397-client-sealing). An org route's secrets are sealed to
// each machine that may use it and to each admin's client; a person's own secrets to their
// machines and their clients. The control plane opens none of them. When a machine or a
// client that may hold one has no copy (it joined, or was paired, after the value was
// sealed), the control plane says control/sealingWanted to the clients that can seal again;
// one that is online calls sealing/work, opens its own copy, seals it to each recipient
// missing, and gives the copies back with sealing/add.

// sealingDebounce gathers the asks of machines that join at once into one notice.
const sealingDebounce = 2 * time.Second

// sealingWants is who is to be told control/sealingWanted, once the debounce ends.
type sealingWants struct {
	mu      sync.Mutex
	people  map[string]bool
	admins  bool
	pending bool
	// asked is each copy already asked for, by item, version and recipient, so a copy that
	// no online client can make is asked for once, not at each sealing/work.
	asked map[string]bool
}

// mostAsked bounds sealingWants.asked; past it, it starts again.
const mostAsked = 10000

// keyed says a record's key is a P-256 public key, X9.63, as a recipient needs.
func keyed(publicKey []byte) bool { return len(publicKey) == 65 && publicKey[0] == 4 }

// clientRecipients are the clients of the people whose ones pass, with a key that has
// not run out.
func (s *Service) clientRecipients(of func(person string) bool) []wire.SealRecipient {
	now := time.Now()
	var out []wire.SealRecipient
	for _, c := range s.records.Clients() {
		if !keyed(c.PublicKey) || c.Expires != nil && c.Expires.Before(now) || !of(s.PersonOf(c.ID)) {
			continue
		}
		out = append(out, wire.SealRecipient{ID: controllink.ClientRecipient(c.ID), Name: c.Name, PublicKey: c.PublicKey})
	}
	return out
}

// machineRecipients are the machines that pass, with a key.
func (s *Service) machineRecipients(takes func(host string) bool) []wire.SealRecipient {
	var out []wire.SealRecipient
	for _, h := range s.records.Hosts() {
		if !keyed(h.PublicKey) || !takes(h.ID) {
			continue
		}
		out = append(out, wire.SealRecipient{ID: controllink.MachineRecipient(h.ID), Name: cmpOr(h.Name, h.ID), PublicKey: h.PublicKey})
	}
	return out
}

func sortedRecipients(list []wire.SealRecipient) []wire.SealRecipient {
	if list == nil {
		return []wire.SealRecipient{}
	}
	sort.Slice(list, func(i, j int) bool { return list[i].ID < list[j].ID })
	return list
}

// routeRecipients are what a route for these groups is sealed to: each machine that keeps
// org routes and whose person may use it, and every admin's client.
func (s *Service) routeRecipients(groups []string) []wire.SealRecipient {
	out := s.machineRecipients(func(host string) bool {
		return s.takesOrgRoutes(host) && s.mayUseGroups(s.ownerOf(host), groups)
	})
	out = append(out, s.clientRecipients(s.isAdmin)...)
	return sortedRecipients(out)
}

// userRecipients are what a person's secret is sealed to: their machines that take
// secrets, and their clients.
func (s *Service) userRecipients(user string) []wire.SealRecipient {
	out := s.machineRecipients(func(host string) bool { return s.takesUserSecrets(host) && s.ownerOf(host) == user })
	out = append(out, s.clientRecipients(func(person string) bool { return person == user })...)
	return sortedRecipients(out)
}

func recipientIDs(list []wire.SealRecipient) map[string]bool {
	out := make(map[string]bool, len(list))
	for _, r := range list {
		out[r.ID] = true
	}
	return out
}

func (m *Methods) sealingMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	user := m.callerPerson(from)
	switch method {
	case "sealing/work":
		return m.s.sealingWork(ctx, user, from.Client)
	case "sealing/add":
		request, err := require[wire.SealingAdd](params, "SealingAdd")
		if err != nil {
			return nil, err
		}
		if len(request.Items) > mostOrgRoutes+usersettings.MaxSecrets {
			return nil, fail(invalidParams, "Too many items.")
		}
		routes := false
		secrets := false
		for _, item := range request.Items {
			switch item.Item {
			case wire.SealingItemKindOrgRoute:
				if !m.s.isAdmin(user) {
					return nil, fail(notPermitted, "Only an admin can seal the organisation's routes.")
				}
				added, err := m.s.addRouteCopies(ctx, item)
				if err != nil {
					return nil, err
				}
				if added {
					routes = true
					m.s.log(fmt.Sprintf("org route %s sealed again for %d more", item.ID, len(item.Values)))
					m.s.announce("orgRoutesChanged", item.ID, user)
				}
			case wire.SealingItemKindUserSecret:
				values := map[string]wire.SealedEnvelope{}
				for recipient, byField := range item.Values {
					if e, ok := byField["value"]; ok && len(byField) == 1 {
						values[recipient] = e
					}
				}
				added, err := m.s.users.AddSealed(ctx, user, item.ID, item.Version, values, recipientIDs(m.s.userRecipients(user)))
				if err != nil {
					return nil, userFailure(err)
				}
				secrets = secrets || added
			default:
				return nil, fail(invalidParams, "%q is not something to seal.", item.Item)
			}
		}
		if routes {
			m.s.orgRoutesChangedHere()
		}
		if secrets {
			m.s.userChanged(user, nil, true, from.Client)
		}
		return wire.Empty{}, nil
	}
	return nil, notFound(method)
}

// sealingWork is sealing/work for one client: each value it has a copy of whose
// recipients do not all have one. A client that has no copy of one it may hold asks the
// others to seal it for this client.
func (s *Service) sealingWork(ctx context.Context, user, client string) (wire.SealingWork, error) {
	out := wire.SealingWork{Items: []wire.SealingItem{}}
	me := controllink.ClientRecipient(client)
	var lacking []string
	if s.isAdmin(user) {
		routes, err := s.readOrgRoutes(ctx)
		if err != nil {
			return out, err
		}
		for _, kept := range routes {
			r := kept.route
			if len(r.SecretFields) == 0 {
				continue
			}
			record, _, err := s.readRouteSecrets(ctx, r.ID)
			if err != nil {
				return out, err
			}
			current := record.SealVersion == deref(r.SealVersion)
			mine := record.Sealed[me]
			if !current || !hasFields(mine, r.SecretFields) {
				lacking = append(lacking, routeAsk(r, me))
				continue
			}
			missing := []wire.SealRecipient{}
			for _, recipient := range s.routeRecipients(r.Groups) {
				if !hasFields(record.Sealed[recipient.ID], r.SecretFields) {
					missing = append(missing, recipient)
				}
			}
			if len(missing) > 0 {
				out.Items = append(out.Items, routeItem(r, mine, missing))
			}
		}
	}
	items, lacks, err := s.users.Work(ctx, user, me, s.userRecipients(user))
	if err != nil {
		return out, userFailure(err)
	}
	out.Items = append(out.Items, items...)
	s.wantSealingByAdmins(lacking...)
	s.wantSealingBy(user, lacks...)
	return out, nil
}

// addRouteCopies keeps the copies a client sealed for a route's recipients that had none,
// at its current seal version. Copies for what is no longer a recipient go.
func (s *Service) addRouteCopies(ctx context.Context, item wire.SealingAddItem) (bool, error) {
	for try := 0; ; try++ {
		kept, err := s.readOrgRoute(ctx, item.ID)
		if err != nil || kept == nil {
			return false, err
		}
		r := kept.route
		record, tag, err := s.readRouteSecrets(ctx, r.ID)
		if err != nil {
			return false, err
		}
		if tag == "" || item.Version != record.SealVersion || item.Version != deref(r.SealVersion) {
			return false, nil
		}
		allowed := recipientIDs(s.routeRecipients(r.Groups))
		next := orgSecretRecord{ID: r.ID, SealVersion: record.SealVersion, Sealed: map[string]map[string]wire.SealedEnvelope{}}
		for recipient, byField := range record.Sealed {
			if allowed[recipient] {
				next.Sealed[recipient] = byField
			}
		}
		added := false
		for recipient, byField := range item.Values {
			if !allowed[recipient] || hasFields(next.Sealed[recipient], r.SecretFields) || !hasFields(byField, r.SecretFields) {
				continue
			}
			for _, e := range byField {
				if len(e.Encapsulated) != 65 || len(e.Ciphertext) > mostRouteSecret+16 || len(e.Ciphertext) < 17 {
					return false, fail(invalidParams, "A secret is at most %d KiB.", mostRouteSecret>>10)
				}
			}
			next.Sealed[recipient] = maps.Clone(byField)
			added = true
		}
		if !added {
			return false, nil
		}
		if len(next.Sealed) > mostRecipients {
			return false, fail(invalidParams, "A key is sealed to at most %d machines and apps.", mostRecipients)
		}
		if _, err := s.writeRouteSecrets(ctx, next, tag); err != nil {
			if store.IsConflict(err) && try < orgRouteRetries {
				continue
			}
			return false, fail(storeUnavailable, "The route's key could not be kept: %v", err)
		}
		return true, nil
	}
}

// routeAsk is the key of one recipient's copy of a route at its seal version.
func routeAsk(r wire.OrgRoute, recipient string) string {
	return fmt.Sprintf("route|%s|%d|%s", r.ID, deref(r.SealVersion), recipient)
}

// newAsksLocked keeps the asks not made before, and says whether there were any.
func (s *Service) newAsksLocked(asks []string) bool {
	if s.sealingWants.asked == nil || len(s.sealingWants.asked) > mostAsked {
		s.sealingWants.asked = map[string]bool{}
	}
	fresh := false
	for _, a := range asks {
		if !s.sealingWants.asked[a] {
			s.sealingWants.asked[a] = true
			fresh = true
		}
	}
	return fresh
}

// wantSealingByAdmins asks every admin's clients to seal the copies asks names, the first
// time each is asked for.
func (s *Service) wantSealingByAdmins(asks ...string) {
	s.sealingWants.mu.Lock()
	if !s.newAsksLocked(asks) {
		s.sealingWants.mu.Unlock()
		return
	}
	s.sealingWants.admins = true
	s.sealingWantsLocked()
}

// wantSealingBy asks a person's clients to seal the copies of theirs asks names.
func (s *Service) wantSealingBy(user string, asks ...string) {
	s.sealingWants.mu.Lock()
	if !s.newAsksLocked(asks) {
		s.sealingWants.mu.Unlock()
		return
	}
	if s.sealingWants.people == nil {
		s.sealingWants.people = map[string]bool{}
	}
	s.sealingWants.people[user] = true
	s.sealingWantsLocked()
}

// sealingWantsLocked tells, once the debounce ends, everyone asked for since.
func (s *Service) sealingWantsLocked() {
	defer s.sealingWants.mu.Unlock()
	if s.sealingWants.pending {
		return
	}
	s.sealingWants.pending = true
	time.AfterFunc(sealingDebounce, func() {
		s.sealingWants.mu.Lock()
		people, admins := s.sealingWants.people, s.sealingWants.admins
		s.sealingWants.people, s.sealingWants.admins, s.sealingWants.pending = nil, false, false
		s.sealingWants.mu.Unlock()
		if admins {
			if s.isAdmin(s.localOwner()) {
				people = orNew(people)
				people[s.localOwner()] = true
			}
			for _, p := range s.records.People() {
				if s.isAdmin(p.ID) {
					people = orNew(people)
					people[p.ID] = true
				}
			}
		}
		for _, person := range slices.Sorted(maps.Keys(people)) {
			s.router.TellPerson(person, wire.NotifyControlSealingWanted.Name, wire.Empty{})
		}
	})
}

func orNew(m map[string]bool) map[string]bool {
	if m == nil {
		return map[string]bool{}
	}
	return m
}

// takesUserSecrets says a machine opens the secrets its person's clients seal to it.
func (s *Service) takesUserSecrets(host string) bool {
	h := s.records.Host(host)
	return h != nil && slices.Contains(hostCapabilities(*h), wire.CapHostUserSettings2)
}

// machineOfRecipient is the machine a recipient names, or "".
func machineOfRecipient(recipient string) string {
	host, _ := strings.CutPrefix(recipient, "m:")
	if host == recipient {
		return ""
	}
	return host
}
