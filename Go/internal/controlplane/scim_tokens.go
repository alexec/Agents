package controlplane

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/scim"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// SCIM tokens (#1002, D12, FR-014): an admin makes a bearer token for one org provider
// and gives it to the provider with the base URL. It is shown once; the store keeps only
// its SHA-256, as the token's key, so a request finds its token with one read. Two tokens
// at most are live for each provider, so one can be rotated with no gap.

const (
	scimTokensPrefix = "v1/scim/tokens/"
	scimTokenPrefix  = "agscim_"
	// mostLiveSCIMTokens is how many tokens of a provider work at once.
	mostLiveSCIMTokens = 2
	// mostSCIMTokens bounds what one provider keeps, revoked ones too: the oldest revoked
	// go first.
	mostSCIMTokens = 20
	// scimTokenKept is how long this copy trusts a token it read: a revoke at another copy
	// is told at once (scimTokenRevoked), and this bounds a missed one.
	scimTokenKept = 10 * time.Second
	// scimLastUseEvery is how often a token's last use is written.
	scimLastUseEvery = time.Minute
)

// scimTokenRecord is v1/scim/tokens/<sha256>.json.
type scimTokenRecord struct {
	ID       string              `json:"id"`
	Provider string              `json:"provider"`
	Name     string              `json:"name"`
	SHA256   string              `json:"sha256"`
	Made     wire.OrgRouteStamp  `json:"made"`
	Ends     *wire.Date          `json:"ends,omitempty"`
	LastUse  *wire.SCIMTokenUse  `json:"lastUse,omitempty"`
	Revoked  *wire.OrgRouteStamp `json:"revoked,omitempty"`
}

func (t scimTokenRecord) live(now time.Time) bool {
	return t.Revoked == nil && (t.Ends == nil || now.Before(t.Ends.Time()))
}

func (t scimTokenRecord) onWire() wire.SCIMToken {
	return wire.SCIMToken{ID: t.ID, Provider: t.Provider, Name: t.Name, Made: t.Made, Ends: t.Ends, LastUse: t.LastUse, Revoked: t.Revoked}
}

func scimTokenKey(sum string) string { return scimTokensPrefix + sum + ".json" }

// scimTokens is what this copy keeps of the tokens it read.
type scimTokens struct {
	s  *Service
	mu sync.Mutex
	// read is each token read, by its hash, and when; noted is when its last use was written.
	read  map[string]keptSCIMToken
	noted map[string]time.Time
}

// mostSCIMTokensKept is how many tokens a copy keeps read before it starts again, as the
// read API does.
const mostSCIMTokensKept = 1000

type keptSCIMToken struct {
	t  *scimTokenRecord
	at time.Time
}

// Authenticate is scim.Tokens: the provider of a live token, its use noted at most once
// a minute (FR-014). A provider that is removed or has SCIM off takes no request.
func (st *scimTokens) Authenticate(ctx context.Context, bearer, address string) (scim.Caller, bool) {
	if !strings.HasPrefix(bearer, scimTokenPrefix) || len(bearer) > 100 {
		return scim.Caller{}, false
	}
	sum := sha256.Sum256([]byte(bearer))
	hash := hex.EncodeToString(sum[:])
	now := time.Now()
	st.mu.Lock()
	kept, ok := st.read[hash]
	st.mu.Unlock()
	if !ok || now.Sub(kept.at) > scimTokenKept {
		t, err := st.get(ctx, hash)
		if err != nil {
			return scim.Caller{}, false
		}
		kept = keptSCIMToken{t, now}
		// An unknown bearer is not kept: anyone can send a million of them (#2425).
		if t != nil {
			st.mu.Lock()
			if st.read == nil || len(st.read) >= mostSCIMTokensKept {
				st.read = map[string]keptSCIMToken{}
			}
			st.read[hash] = kept
			st.mu.Unlock()
		}
	}
	if kept.t == nil || !kept.t.live(now) {
		return scim.Caller{}, false
	}
	if p, err := st.s.signIns.orgProviderOn(ctx, kept.t.Provider); err != nil || p.Scim == nil || !p.Scim.On {
		return scim.Caller{}, false
	}
	st.noteUse(hash, address, now)
	return scim.Caller{Provider: kept.t.Provider, Token: kept.t.ID}, true
}

func (st *scimTokens) get(ctx context.Context, hash string) (*scimTokenRecord, error) {
	object, err := st.s.cfg.Store.Get(ctx, scimTokenKey(hash))
	if err != nil || object == nil {
		return nil, err
	}
	var t scimTokenRecord
	if json.Unmarshal(object.Data, &t) != nil || t.SHA256 != hash {
		return nil, nil
	}
	return &t, nil
}

// noteUse writes a token's last use, at most once a minute, in the background.
func (st *scimTokens) noteUse(hash, address string, now time.Time) {
	st.mu.Lock()
	if st.noted == nil {
		st.noted = map[string]time.Time{}
	}
	if now.Sub(st.noted[hash]) < scimLastUseEvery {
		st.mu.Unlock()
		return
	}
	st.noted[hash] = now
	st.mu.Unlock()
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		key := scimTokenKey(hash)
		object, err := st.s.cfg.Store.Get(ctx, key)
		if err != nil || object == nil {
			return
		}
		var t scimTokenRecord
		if json.Unmarshal(object.Data, &t) != nil || t.Revoked != nil {
			return
		}
		t.LastUse = &wire.SCIMTokenUse{At: wire.DateOf(now), Address: optional(address)}
		if data, err := records.Encode(t); err == nil {
			// A revoke in between wins: its write moved the tag.
			_, _ = st.s.cfg.Store.Put(ctx, key, data, store.Matching(object.ETag))
		}
	}()
}

// forget drops what this copy read, after a revoke here or at another copy.
func (st *scimTokens) forget() {
	st.mu.Lock()
	st.read = nil
	st.mu.Unlock()
}

// list is every token of a provider, newest first.
func (st *scimTokens) list(ctx context.Context, provider string) ([]scimTokenRecord, map[string]string, error) {
	keys, err := st.s.cfg.Store.List(ctx, scimTokensPrefix)
	if err != nil {
		return nil, nil, fail(storeUnavailable, "The SCIM tokens could not be read: %v", err)
	}
	var out []scimTokenRecord
	etags := map[string]string{}
	for _, k := range keys {
		object, err := st.s.cfg.Store.Get(ctx, k.Key)
		if err != nil {
			return nil, nil, fail(storeUnavailable, "The SCIM tokens could not be read: %v", err)
		}
		var t scimTokenRecord
		if object == nil || json.Unmarshal(object.Data, &t) != nil || t.Provider != provider {
			continue
		}
		out = append(out, t)
		etags[t.ID] = object.ETag
	}
	sortNewestFirst(out)
	return out, etags, nil
}

func sortNewestFirst(list []scimTokenRecord) {
	for i := 1; i < len(list); i++ {
		for j := i; j > 0 && list[j].Made.At.Time().After(list[j-1].Made.At.Time()); j-- {
			list[j], list[j-1] = list[j-1], list[j]
		}
	}
}

// make is scim/tokens/make: a new token, refused while two are live.
func (st *scimTokens) make(ctx context.Context, r wire.SCIMTokenMake, actor wire.AuditActor) (wire.SCIMTokenMade, error) {
	p, err := st.s.signIns.orgProviderOn(ctx, r.Provider)
	if err != nil {
		return wire.SCIMTokenMade{}, err
	}
	name := strings.TrimSpace(r.Name)
	if name == "" || len([]rune(name)) > 60 {
		return wire.SCIMTokenMade{}, fail(invalidParams, "Give the token a name of 1 to 60 characters.")
	}
	now := time.Now()
	if r.Ends != nil && !r.Ends.Time().After(now) {
		return wire.SCIMTokenMade{}, fail(invalidParams, "A token's end is in the future.")
	}
	base, ok := st.s.signIns.httpsBase()
	if !ok {
		return wire.SCIMTokenMade{}, fail(orgProviderUnavailable, "SCIM needs this control plane's HTTPS address.")
	}
	all, _, err := st.list(ctx, p.ID)
	if err != nil {
		return wire.SCIMTokenMade{}, err
	}
	live := 0
	for _, t := range all {
		if t.live(now) {
			live++
		}
	}
	if live >= mostLiveSCIMTokens {
		return wire.SCIMTokenMade{}, fail(notPermitted, "%s has %d live SCIM tokens. Revoke one first.", p.Name, live)
	}
	value := scimTokenPrefix + randomToken(32)
	sum := sha256.Sum256([]byte(value))
	hash := hex.EncodeToString(sum[:])
	t := scimTokenRecord{ID: hash[:12], Provider: p.ID, Name: name, SHA256: hash, Made: wire.OrgRouteStamp{By: actor, At: wire.DateOf(now)},
		Ends: r.Ends}
	data, err := records.Encode(t)
	if err == nil {
		_, err = st.s.cfg.Store.Put(ctx, scimTokenKey(hash), data, store.Absent)
	}
	if err != nil {
		return wire.SCIMTokenMade{}, fail(storeUnavailable, "The token could not be kept: %v", err)
	}
	st.trim(ctx, append(all, t))
	st.s.signIns.auditOrg(actor, "scim/tokens/make", p.ID, "token "+t.ID+" ("+name+")")
	st.s.log("a SCIM token " + t.ID + " was made for org provider " + p.ID)
	return wire.SCIMTokenMade{Token: t.onWire(), Value: value, URL: base + scim.Base}, nil
}

// trim deletes the oldest revoked or ended tokens over mostSCIMTokens.
func (st *scimTokens) trim(ctx context.Context, all []scimTokenRecord) {
	sortNewestFirst(all)
	now := time.Now()
	kept := 0
	for _, t := range all {
		if t.live(now) || kept < mostSCIMTokens {
			kept++
			continue
		}
		_ = st.s.cfg.Store.Delete(ctx, scimTokenKey(t.SHA256))
	}
}

// revoke is scim/tokens/revoke: the token stops working at once, at every copy.
func (st *scimTokens) revoke(ctx context.Context, id string, actor wire.AuditActor) error {
	keys, err := st.s.cfg.Store.List(ctx, scimTokensPrefix)
	if err != nil {
		return fail(storeUnavailable, "The SCIM tokens could not be read: %v", err)
	}
	for _, k := range keys {
		if !strings.HasPrefix(strings.TrimPrefix(k.Key, scimTokensPrefix), id) || len(id) < 12 {
			continue
		}
		object, err := st.s.cfg.Store.Get(ctx, k.Key)
		if err != nil {
			return fail(storeUnavailable, "The token could not be read: %v", err)
		}
		var t scimTokenRecord
		if object == nil || json.Unmarshal(object.Data, &t) != nil || t.ID != id {
			continue
		}
		if t.Revoked != nil {
			return nil
		}
		t.Revoked = &wire.OrgRouteStamp{By: actor, At: wire.DateOf(time.Now())}
		data, _ := records.Encode(t)
		if _, err := st.s.cfg.Store.Put(ctx, k.Key, data, store.Matching(object.ETag)); err != nil {
			if store.IsConflict(err) {
				return fail(changedElsewhere, "The token was changed elsewhere a moment ago. Try again.")
			}
			return fail(storeUnavailable, "The token could not be kept: %v", err)
		}
		st.forget()
		st.s.announce("scimTokenRevoked", t.Provider, "")
		st.s.signIns.auditOrg(actor, "scim/tokens/revoke", t.Provider, "token "+t.ID+" ("+t.Name+")")
		st.s.log("SCIM token " + t.ID + " of org provider " + t.Provider + " was revoked")
		return nil
	}
	return fail(invalidParams, "There is no such SCIM token.")
}

// setSCIM is scim/set: SCIM on or off for a provider, and its match attribute. The
// provider's version goes up, as for any change to it.
func (si *signIns) setSCIM(ctx context.Context, r wire.SCIMSet, actor wire.AuditActor) (wire.OrgProviderKept, error) {
	kept, err := si.readOrgProvider(ctx, r.Provider)
	if err != nil {
		return wire.OrgProviderKept{}, err
	}
	if kept == nil || kept.removed {
		return wire.OrgProviderKept{}, fail(invalidParams, "There is no org provider %q.", r.Provider)
	}
	match := wire.SCIMMatchExternalId
	if r.Match != nil {
		match = *r.Match
	}
	if match != wire.SCIMMatchExternalId && match != wire.SCIMMatchUserName {
		return wire.OrgProviderKept{}, fail(invalidParams, "The match is externalId or userName.")
	}
	p := kept.p
	p.Scim = &wire.OrgProviderSCIM{On: r.On, Match: match}
	p.Version = new(deref(p.Version) + 1)
	p.Changed = &wire.OrgRouteStamp{By: actor, At: wire.DateOf(si.clock())}
	p.RedirectURI = nil
	data, err := records.Encode(orgProviderStored{OrgProvider: p})
	if err != nil {
		return wire.OrgProviderKept{}, err
	}
	rev, err := si.s.cfg.Store.Put(ctx, orgProviderKey(p.ID), data, store.Matching(kept.rev))
	if err != nil {
		if store.IsConflict(err) {
			return wire.OrgProviderKept{}, fail(changedElsewhere, "This provider was changed elsewhere. Read it again.")
		}
		return wire.OrgProviderKept{}, fail(storeUnavailable, "The provider could not be kept: %v", err)
	}
	what := "SCIM off"
	if r.On {
		what = "SCIM on, matched by " + string(match)
	}
	si.auditOrg(actor, "scim/set", p.ID, what)
	si.s.log("org provider " + p.ID + ": " + what)
	si.s.peopleChanged("", false)
	p.RedirectURI = new(si.redirectURI())
	return wire.OrgProviderKept{Provider: p, Rev: rev}, nil
}

// scimMethod answers scim/set and scim/tokens/*: each an admin's.
func (m *Methods) scimMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	if !m.s.isAdmin(m.callerPerson(from)) {
		return nil, fail(notPermitted, "Only an admin changes SCIM.")
	}
	actor := m.s.actorFor(from.Client)
	switch method {
	case "scim/set":
		r, err := require[wire.SCIMSet](params, "SCIMSet")
		if err != nil {
			return nil, err
		}
		return m.s.signIns.setSCIM(ctx, r, actor)
	case "scim/tokens/list":
		r, err := require[wire.SCIMTokensRequest](params, "SCIMTokensRequest")
		if err != nil {
			return nil, err
		}
		all, _, err := m.s.scimTokens.list(ctx, r.Provider)
		if err != nil {
			return nil, err
		}
		out := wire.SCIMTokenList{Tokens: []wire.SCIMToken{}}
		for _, t := range all {
			out.Tokens = append(out.Tokens, t.onWire())
		}
		return out, nil
	case "scim/tokens/make":
		r, err := require[wire.SCIMTokenMake](params, "SCIMTokenMake")
		if err != nil {
			return nil, err
		}
		return m.s.scimTokens.make(ctx, r, actor)
	case "scim/tokens/revoke":
		r, err := require[wire.SCIMTokenRequest](params, "SCIMTokenRequest")
		if err != nil {
			return nil, err
		}
		return wire.Empty{}, m.s.scimTokens.revoke(ctx, r.ID, actor)
	}
	return nil, fail(methodNotFound, "%s", method)
}
