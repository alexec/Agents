package controlplane

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net"
	"slices"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/signin"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Claimed domains (#1002, D8, D9, FR-010 to FR-012): an admin claims an email domain for
// one org provider and proves it with a TXT record agents-domain=<token> at
// _agents.<domain>. A proved domain can send people to its provider (signIn/discover) and
// can require it: a Google, Apple or GitHub sign-in at the domain cannot join, pair or
// renew a key. The local owner is never refused. The control plane checks each proved
// domain once a day; 7 days of failures take the claim back.

const (
	domainsPrefix = "v1/signin/domains/"
	// mostDomains is how many domains one control plane claims (spec Assumptions).
	mostDomains = 20
	// domainCheckEvery is how often a proved domain is checked again; domainGrace how long
	// it may fail before its claim goes.
	domainCheckEvery = 24 * time.Hour
	domainGrace      = 7 * 24 * time.Hour
	// claimsKept is how long a copy keeps the claims it read, for renewals and sign-ins.
	claimsKept = time.Minute
)

// Resolver is the DNS, for the TXT proof: net.DefaultResolver, or a fake in tests.
type Resolver interface {
	LookupTXT(ctx context.Context, name string) ([]string, error)
}

// domainStored is a claim as the store keeps it, with when it was last checked.
type domainStored struct {
	wire.DomainClaim
	Checked *records.Stamp `json:"checked,omitempty"`
}

type keptClaim struct {
	claim   wire.DomainClaim
	checked *records.Stamp
	rev     string
}

func domainKey(domain string) string { return domainsPrefix + domain + ".json" }

func (si *signIns) resolver() Resolver {
	si.org.mu.Lock()
	defer si.org.mu.Unlock()
	if si.org.dns != nil {
		return si.org.dns
	}
	return net.DefaultResolver
}

// cleanDomain is a domain as it is claimed: lower case, no trailing dot.
func cleanDomain(d string) (string, error) {
	d = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(d)), ".")
	if !domainPattern.MatchString(d) || len(d) > 253 {
		return "", fail(invalidParams, "%q is not a domain.", d)
	}
	return d, nil
}

// emailDomain is the domain of an email address, or "".
func emailDomain(email string) string {
	_, d, ok := strings.Cut(strings.ToLower(strings.TrimSpace(email)), "@")
	if !ok {
		return ""
	}
	return strings.TrimSuffix(d, ".")
}

func (si *signIns) readClaim(ctx context.Context, domain string) (*keptClaim, error) {
	object, err := si.s.cfg.Store.Get(ctx, domainKey(domain))
	if err != nil {
		return nil, fail(storeUnavailable, "The domains could not be read: %v", err)
	}
	if object == nil {
		return nil, nil
	}
	var d domainStored
	if json.Unmarshal(object.Data, &d) != nil || d.Domain != domain {
		return nil, nil
	}
	return &keptClaim{claim: d.DomainClaim, checked: d.Checked, rev: object.ETag}, nil
}

// domainClaims is every claim: kept for claimsKept, or read again when fresh.
func (si *signIns) domainClaims(ctx context.Context, fresh bool) []keptClaim {
	si.org.mu.Lock()
	if !fresh && si.org.claims != nil && time.Since(si.org.claimsAt) < claimsKept {
		out := si.org.claims
		si.org.mu.Unlock()
		return out
	}
	si.org.mu.Unlock()
	keys, err := si.s.cfg.Store.List(ctx, domainsPrefix)
	if err != nil {
		si.org.mu.Lock()
		defer si.org.mu.Unlock()
		return si.org.claims
	}
	out := []keptClaim{}
	for _, k := range keys {
		domain := strings.TrimSuffix(strings.TrimPrefix(k.Key, domainsPrefix), ".json")
		if c, err := si.readClaim(ctx, domain); err == nil && c != nil {
			out = append(out, *c)
		}
	}
	si.org.mu.Lock()
	si.org.claims, si.org.claimsAt = out, time.Now()
	si.org.mu.Unlock()
	return out
}

// forgetClaims makes the next read go to the store: after a change at this copy.
func (si *signIns) forgetClaims() {
	si.org.mu.Lock()
	si.org.claims = nil
	si.org.mu.Unlock()
}

// provedDomains are a provider's proved domains.
func (si *signIns) provedDomains(ctx context.Context, provider string) []string {
	out := []string{}
	for _, c := range si.domainClaims(ctx, false) {
		if c.claim.Provider == provider && c.claim.State == wire.DomainClaimStateProved {
			out = append(out, c.claim.Domain)
		}
	}
	return out
}

// claimFor is the proved claim of an email's domain, or nil.
func (si *signIns) claimFor(ctx context.Context, email string) *wire.DomainClaim {
	d := emailDomain(email)
	if d == "" {
		return nil
	}
	for _, c := range si.domainClaims(ctx, false) {
		if c.claim.Domain == d && c.claim.State == wire.DomainClaimStateProved {
			return &c.claim
		}
	}
	return nil
}

func (si *signIns) writeClaim(ctx context.Context, c wire.DomainClaim, checked *records.Stamp, when store.Condition) (string, error) {
	data, err := records.Encode(domainStored{DomainClaim: c, Checked: checked})
	if err != nil {
		return "", err
	}
	rev, err := si.s.cfg.Store.Put(ctx, domainKey(c.Domain), data, when)
	si.forgetClaims()
	return rev, err
}

// claimDomain is signIn/domains/claim: one domain, one provider (US3 AS5).
func (si *signIns) claimDomain(ctx context.Context, r wire.SignInDomainClaim, actor wire.AuditActor) (wire.DomainClaim, error) {
	domain, err := cleanDomain(r.Domain)
	if err != nil {
		return wire.DomainClaim{}, err
	}
	kept, err := si.readOrgProvider(ctx, r.Provider)
	if err != nil {
		return wire.DomainClaim{}, err
	}
	if kept == nil || kept.removed {
		return wire.DomainClaim{}, fail(invalidParams, "There is no org provider called %q.", r.Provider)
	}
	if there, err := si.readClaim(ctx, domain); err != nil {
		return wire.DomainClaim{}, err
	} else if there != nil {
		if there.claim.Provider == r.Provider {
			return there.claim, nil
		}
		return wire.DomainClaim{}, fail(invalidParams, "%s is claimed for another provider. Remove that claim first.", domain)
	}
	if len(si.domainClaims(ctx, true)) >= mostDomains {
		return wire.DomainClaim{}, fail(invalidParams, "A control plane claims %d domains at most.", mostDomains)
	}
	token := make([]byte, 16)
	rand.Read(token)
	now := si.clock()
	c := wire.DomainClaim{Domain: domain, Provider: r.Provider, State: wire.DomainClaimStateNotProved, TxtName: "_agents." + domain,
		TxtValue: "agents-domain=" + hex.EncodeToString(token), Claimed: &wire.OrgRouteStamp{By: actor, At: wire.DateOf(now)}}
	if _, err := si.writeClaim(ctx, c, nil, store.Absent); err != nil {
		if store.IsConflict(err) {
			return wire.DomainClaim{}, fail(changedElsewhere, "%s was claimed elsewhere a moment ago. Read the domains again.", domain)
		}
		return wire.DomainClaim{}, fail(storeUnavailable, "The claim could not be kept: %v", err)
	}
	si.auditOrg(actor, "signIn/domains/claim", domain, "for "+kept.p.Name)
	return c, nil
}

// proves says the domain's TXT record is there now. A lookup that fails is not a proof.
func (si *signIns) proves(ctx context.Context, c wire.DomainClaim) bool {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	found, err := si.resolver().LookupTXT(ctx, c.TxtName)
	if err != nil {
		return false
	}
	return slices.Contains(found, c.TxtValue)
}

// checkClaim looks for a claim's record and keeps what it found (D8): found, it is
// proved; not found, a claim not proved stays so, and a proved one fails until 7 days
// have passed, when it goes back to notProved with its switches off.
func (si *signIns) checkClaim(ctx context.Context, k keptClaim, actor wire.AuditActor) (wire.DomainClaim, error) {
	c := k.claim
	now := si.clock()
	stamp := records.At(now)
	method, what := "", ""
	if si.proves(ctx, c) {
		if c.State != wire.DomainClaimStateProved {
			method, what = "signIn/domains/check", "proved"
		}
		c.State, c.LastGood, c.FailingSince = wire.DomainClaimStateProved, new(wire.DateOf(now)), nil
	} else if c.State == wire.DomainClaimStateProved {
		if c.FailingSince == nil {
			c.FailingSince = new(wire.DateOf(now))
		}
		if now.Sub(c.FailingSince.Time()) >= domainGrace {
			c.State, c.SendHere, c.Require, c.FailingSince = wire.DomainClaimStateNotProved, false, false, nil
			method, what = "signIn/domains/lost", "its TXT record was not found for 7 days: not proved, and its switches are off"
		}
	}
	if _, err := si.writeClaim(ctx, c, &stamp, store.Matching(k.rev)); err != nil {
		if store.IsConflict(err) {
			return c, fail(changedElsewhere, "%s was changed elsewhere a moment ago. Check it again.", c.Domain)
		}
		return c, fail(storeUnavailable, "The claim could not be kept: %v", err)
	}
	if method != "" {
		si.auditOrg(actor, method, c.Domain, what)
		si.s.log("domain " + c.Domain + ": " + what)
		if method == "signIn/domains/lost" {
			// The admins' screens read the claims again.
			si.s.peopleChanged("", false)
		}
	} else if actor.User != "" {
		si.auditOrg(actor, "signIn/domains/check", c.Domain, string(c.State))
	}
	return c, nil
}

// checkDomains is the daily check (FR-010): each proved domain not checked for a day.
func (si *signIns) checkDomains(ctx context.Context) {
	now := si.clock()
	for _, k := range si.domainClaims(ctx, true) {
		if k.claim.State != wire.DomainClaimStateProved || k.checked != nil && now.Sub(k.checked.Time) < domainCheckEvery {
			continue
		}
		if _, err := si.checkClaim(ctx, k, wire.AuditActor{}); err != nil {
			si.s.log("domain " + k.claim.Domain + " could not be checked: " + asRPC(err).Message)
		}
	}
}

// sweepOIDC deletes the states and tickets an hour old, with their marks.
func (si *signIns) sweepOIDC(ctx context.Context) {
	now := si.clock()
	for _, prefix := range []string{oidcStatePrefix, oidcTicketPrefix} {
		keys, err := si.s.cfg.Store.List(ctx, prefix)
		if err != nil {
			continue
		}
		for _, k := range keys {
			if !strings.HasSuffix(k.Key, ".json") {
				continue
			}
			object, err := si.s.cfg.Store.Get(ctx, k.Key)
			if err != nil || object == nil {
				continue
			}
			var made struct {
				Made records.Stamp `json:"made"`
			}
			if json.Unmarshal(object.Data, &made) == nil && now.Sub(made.Made.Time) < oidcSweepAfter {
				continue
			}
			base := strings.TrimSuffix(k.Key, ".json")
			si.s.cfg.Store.Delete(ctx, base+usedSuffix)
			si.s.cfg.Store.Delete(ctx, k.Key)
		}
	}
}

// checkEvery checks the domains and sweeps the flows, once an hour, while serving.
func (si *signIns) checkEvery(every time.Duration, stop <-chan struct{}) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			if si.s.phase.now() == phaseServing {
				si.checkDomains(context.Background())
				si.sweepOIDC(context.Background())
				// Leavers without SCIM, once a day each (#1002, Q1 A).
				si.checkRefreshes(context.Background())
			}
		}
	}
}

// setDomain is signIn/domains/set: either switch needs a proved domain (US3 AS1).
func (si *signIns) setDomain(ctx context.Context, r wire.SignInDomainSet, actor wire.AuditActor) (wire.DomainClaim, error) {
	domain, err := cleanDomain(r.Domain)
	if err != nil {
		return wire.DomainClaim{}, err
	}
	k, err := si.readClaim(ctx, domain)
	if err != nil {
		return wire.DomainClaim{}, err
	}
	if k == nil {
		return wire.DomainClaim{}, fail(invalidParams, "%s is not claimed.", domain)
	}
	c := k.claim
	if r.SendHere != nil {
		c.SendHere = *r.SendHere
	}
	if r.Require != nil {
		c.Require = *r.Require
	}
	if (c.SendHere || c.Require) && c.State != wire.DomainClaimStateProved {
		return wire.DomainClaim{}, fail(notPermitted, "Prove %s first.", domain)
	}
	if _, err := si.writeClaim(ctx, c, k.checked, store.Matching(k.rev)); err != nil {
		if store.IsConflict(err) {
			return wire.DomainClaim{}, fail(changedElsewhere, "%s was changed elsewhere a moment ago. Read it again.", domain)
		}
		return wire.DomainClaim{}, fail(storeUnavailable, "The claim could not be kept: %v", err)
	}
	what := []string{}
	if c.SendHere != k.claim.SendHere {
		what = append(what, "send people here "+onOff(c.SendHere))
	}
	if c.Require != k.claim.Require {
		what = append(what, "require this provider "+onOff(c.Require))
	}
	if len(what) > 0 {
		si.auditOrg(actor, "signIn/domains/set", domain, strings.Join(what, ", "))
	}
	si.s.peopleChanged("", false)
	return c, nil
}

func onOff(on bool) string {
	if on {
		return "on"
	}
	return "off"
}

func (si *signIns) removeDomain(ctx context.Context, r wire.SignInDomainRequest, actor wire.AuditActor) error {
	domain, err := cleanDomain(r.Domain)
	if err != nil {
		return err
	}
	k, err := si.readClaim(ctx, domain)
	if err != nil {
		return err
	}
	if k == nil {
		return fail(invalidParams, "%s is not claimed.", domain)
	}
	if err := si.s.cfg.Store.Delete(ctx, domainKey(domain)); err != nil {
		return fail(storeUnavailable, "The claim could not be removed: %v", err)
	}
	si.forgetClaims()
	si.auditOrg(actor, "signIn/domains/remove", domain, "")
	si.s.peopleChanged("", false)
	return nil
}

func (si *signIns) listDomains(ctx context.Context) wire.SignInDomainList {
	out := wire.SignInDomainList{Domains: []wire.DomainClaim{}}
	for _, k := range si.domainClaims(ctx, true) {
		out.Domains = append(out.Domains, k.claim)
	}
	slices.SortFunc(out.Domains, func(a, b wire.DomainClaim) int { return strings.Compare(a.Domain, b.Domain) })
	return out
}

// builtInAt are a person's Google, Apple and GitHub sign-ins whose email is at domain.
func builtInAt(p records.Person, domain string) []records.SignIn {
	out := []records.SignIn{}
	for _, in := range p.SignIns {
		if outsideProvider(in.Provider) && emailDomain(in.Email) == domain {
			out = append(out, in)
		}
	}
	return out
}

// previewDomain is signIn/domains/preview (FR-012): the people whose built-in sign-ins at
// the domain Require refuses. The local owner is never one of them.
func (si *signIns) previewDomain(ctx context.Context, r wire.SignInDomainRequest) (wire.SignInDomainPreview, error) {
	domain, err := cleanDomain(r.Domain)
	if err != nil {
		return wire.SignInDomainPreview{}, err
	}
	out := wire.SignInDomainPreview{People: []wire.SignInDomainPreviewPerson{}}
	owner := si.s.localOwner()
	for _, p := range si.s.records.People() {
		if p.ID == owner || p.IsRemoved() || p.IsBot() {
			continue
		}
		ins := builtInAt(p, domain)
		if len(ins) == 0 {
			continue
		}
		row := wire.SignInDomainPreviewPerson{User: p.ID, Name: p.Name, SignIns: []wire.SignIn{}}
		for _, in := range ins {
			row.SignIns = append(row.SignIns, wire.SignIn{Provider: in.Provider, Email: optional(in.Email)})
		}
		out.People = append(out.People, row)
	}
	slices.SortFunc(out.People, func(a, b wire.SignInDomainPreviewPerson) int { return strings.Compare(a.Name, b.Name) })
	return out, nil
}

// discover is signIn/discover (FR-011): the same answer for an unknown domain and a domain
// that does not send people.
func (si *signIns) discover(ctx context.Context, r wire.SignInDiscover) wire.SignInDiscovered {
	c := si.claimFor(ctx, r.Email)
	if c == nil || !c.SendHere {
		return wire.SignInDiscovered{}
	}
	p, err := si.orgProviderOn(ctx, c.Provider)
	if err != nil {
		return wire.SignInDiscovered{}
	}
	return wire.SignInDiscovered{Provider: &p.ID, Name: &p.Name}
}

// discovers says a proved domain sends people to a provider that is on: a client offers
// Use an Email.
func (si *signIns) discovers(ctx context.Context) bool {
	for _, k := range si.domainClaims(ctx, false) {
		if k.claim.State == wire.DomainClaimStateProved && k.claim.SendHere {
			if _, err := si.orgProviderOn(ctx, k.claim.Provider); err == nil {
				return true
			}
		}
	}
	return false
}

// MARK: Require this provider (D9, FR-012)

// requiredFor is the refusal of a built-in sign-in whose email is at a domain that
// requires its provider, or nil. The local owner is never refused.
func (si *signIns) requiredFor(ctx context.Context, provider, email, person string) error {
	if !outsideProvider(provider) || email == "" || person != "" && person == si.s.localOwner() {
		return nil
	}
	c := si.claimFor(ctx, email)
	if c == nil || !c.Require {
		return nil
	}
	name := c.Provider
	if kept, err := si.readOrgProvider(ctx, c.Provider); err == nil && kept != nil && !kept.removed {
		name = kept.p.Name
	}
	data, _ := json.Marshal(map[string]string{"provider": c.Provider, "name": name})
	who := person
	if who == "" {
		who = provider + ":" + email
	}
	si.auditOrg(wire.AuditActor{User: who}, "signIn/refusedByRequire", emailDomain(email), signin.Title(provider)+" sign-in refused")
	return &RPCError{Code: orgSignInRequired, Message: "Your organisation asks you to sign in with " + name + ".", Data: data}
}

// refusesRenewal says a client's key is not renewed (D9): its person signs in with a
// built-in provider at a domain that requires another, and has no sign-in with that
// one. Their clients work until their keys end.
func (si *signIns) refusesRenewal(ctx context.Context, person string) bool {
	if person == "" || person == si.s.localOwner() {
		return false
	}
	p := si.s.records.Person(person)
	if p == nil {
		return false
	}
	claims := si.domainClaims(ctx, false)
	if len(claims) == 0 {
		return false
	}
	for _, k := range claims {
		c := k.claim
		if c.State != wire.DomainClaimStateProved || !c.Require || len(builtInAt(*p, c.Domain)) == 0 {
			continue
		}
		if !slices.ContainsFunc(p.SignIns, func(in records.SignIn) bool { return in.Provider == c.Provider }) {
			return true
		}
	}
	return false
}
