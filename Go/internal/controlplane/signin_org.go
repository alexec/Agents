package controlplane

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/audit"
	"github.com/alexec/agents/Go/internal/controlplane/kms"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/signin"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Org providers (#1002, spec 1002 slice 1): an organisation's own OIDC provider (Okta,
// Entra, Google Workspace with its own client, or any other), beside Google, Apple and
// GitHub. The control plane is the confidential client (D2): it keeps the client secret
// sealed with the keeper for secrets (D4), runs the code flow with PKCE on its own https
// address (identity_oidc_http.go), and gives the client a ticket for one use, bound to the
// connection that started the flow (D3). No ID token, access token or secret leaves it,
// or is written in the clear.

const (
	orgProvidersPrefix = "v1/signin/providers/"
	orgProviderSecret  = ".secret.json"
	// mostOrgProviders is how many org providers one control plane has (D7).
	mostOrgProviders = 5
	oidcStatePrefix  = "v1/oidc/state/"
	oidcTicketPrefix = "v1/oidc/tickets/"
	// stateLife is how long a started flow waits for its callback; ticketLife how long a
	// ticket waits for signIn/ticket (D3). Both are swept an hour after they are made.
	stateLife      = 10 * time.Minute
	ticketLife     = 2 * time.Minute
	oidcSweepAfter = time.Hour
	usedSuffix     = ".used"
)

const (
	orgSignInRequired      = -32077
	orgProviderUnavailable = -32082
)

var (
	orgProviderIDPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$`)
	claimPattern         = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,64}$`)
	scopePattern         = regexp.MustCompile(`^[\x21\x23-\x5B\x5D-\x7E]{1,64}$`)
)

// orgProviderStored is an org provider as the store keeps it: a removed one stays as a
// tombstone, so its id, the provider of its sign-ins, is never given to another issuer.
type orgProviderStored struct {
	wire.OrgProvider
	Removed *records.Stamp `json:"removed,omitempty"`
}

type keptProvider struct {
	p       wire.OrgProvider
	removed bool
	rev     string
}

// sealedRecord is a sealed envelope in the store, bound to its own key.
type sealedRecord struct {
	ID     string      `json:"id"`
	Sealed *kms.Sealed `json:"sealed"`
}

func orgProviderKey(id string) string       { return orgProvidersPrefix + id + ".json" }
func orgProviderSecretKey(id string) string { return orgProvidersPrefix + id + orgProviderSecret }

// orgState is a started flow (data-model.md): the PKCE verifier and the nonce are sealed,
// so the store holds nothing that could finish it.
type orgState struct {
	Provider  string        `json:"provider"`
	Purpose   string        `json:"purpose"`
	ReturnTo  string        `json:"returnTo"`
	Bind      string        `json:"bind"`
	Person    string        `json:"person,omitempty"`
	LoginHint string        `json:"loginHint,omitempty"`
	Made      records.Stamp `json:"made"`
	Ends      records.Stamp `json:"ends"`
	Sealed    *kms.Sealed   `json:"sealed"`
}

type stateSecrets struct {
	Verifier string `json:"verifier"`
	Nonce    string `json:"nonce"`
}

// orgTicket is what a callback proved, waiting for the connection that started it.
type orgTicket struct {
	Provider string        `json:"provider"`
	Account  string        `json:"account"`
	Email    string        `json:"email,omitempty"`
	Name     string        `json:"name,omitempty"`
	Purpose  string        `json:"purpose"`
	ReturnTo string        `json:"returnTo"`
	Bind     string        `json:"bind"`
	Person   string        `json:"person,omitempty"`
	Made     records.Stamp `json:"made"`
	Ends     records.Stamp `json:"ends"`
	// The refresh token, sealed and bound to the ticket's key (Q1 A), moved to the person
	// when the ticket is spent.
	Refresh *kms.Sealed `json:"refresh,omitempty"`
	key     string
}

// orgBits is what signIns keeps for org providers at this copy.
type orgBits struct {
	discoveries signin.Discoveries
	mu          sync.Mutex
	// One checker per provider, so each keeps its JWKS.
	checkers map[string]*signin.OIDC
	// The claimed domains, read again at most once a minute (signin_domains.go).
	claims   []keptClaim
	claimsAt time.Time
	// skew moves the clock, and dns is the DNS: tests change them.
	skew atomic.Int64
	dns  Resolver
}

func (si *signIns) clock() time.Time { return time.Now().Add(time.Duration(si.org.skew.Load())) }

// storeKeyHash is where a secret value (a state id, a ticket) is kept: by its hash, so a
// store listing says none of them.
func storeKeyHash(prefix, value string) string {
	sum := sha256.Sum256([]byte(value))
	return prefix + hex.EncodeToString(sum[:])
}

func randomToken(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

// binding is what a flow is bound to: the hello's nonce of an s: connection, or a paired
// client's session and person. The web page's flow leaves the page and its connection
// (FR-027, the same tab), so it is bound to what the page keeps instead: the key it
// proved on its s: connection and that connection's id, or its paired client and person.
type binding struct {
	hello   []byte
	session string
	person  string
	// The s: connection's id and public key, or the paired client's id.
	client string
	public []byte
}

// to is the binding for a flow that comes back to returnTo.
func (b binding) to(returnTo string) binding {
	if returnTo != string(wire.SignInOrgReturnWeb) || b.client == "" {
		return binding{hello: b.hello, session: b.session, person: b.person}
	}
	return binding{client: strings.ToUpper(b.client), public: b.public, person: b.person}
}

func (b binding) hash() string {
	h := sha256.New()
	switch {
	case b.client != "" && b.public != nil:
		h.Write([]byte("agents-oidc-key\x00" + b.client + "\x00"))
		h.Write(b.public)
	case b.client != "":
		h.Write([]byte("agents-oidc-client\x00" + b.client + "\x00" + b.person))
	case b.hello != nil:
		h.Write([]byte("agents-oidc-hello\x00"))
		h.Write(b.hello)
	default:
		h.Write([]byte("agents-oidc-session\x00" + b.session + "\x00" + b.person))
	}
	return hex.EncodeToString(h.Sum(nil))
}

// MARK: The https address

// httpsBase is this control plane's own https address, where the provider sends the
// browser back (D18): its URL's origin. http is let through only on loopback, for a Mac's
// own page and tests.
func (si *signIns) httpsBase() (string, bool) {
	u, err := url.Parse(si.s.cfg.URL)
	if err != nil || u.Host == "" {
		return "", false
	}
	switch strings.ToLower(u.Scheme) {
	case "https", "wss":
		return "https://" + u.Host, true
	case "http", "ws":
		host := u.Hostname()
		if ip := net.ParseIP(host); host == "localhost" || ip != nil && ip.IsLoopback() {
			return "http://" + u.Host, true
		}
	}
	return "", false
}

func (si *signIns) redirectURI() string {
	base, _ := si.httpsBase()
	return base + "/v1/oidc/callback"
}

// MARK: Records

func (si *signIns) readOrgProvider(ctx context.Context, id string) (*keptProvider, error) {
	if !orgProviderIDPattern.MatchString(id) {
		return nil, nil
	}
	object, err := si.s.cfg.Store.Get(ctx, orgProviderKey(id))
	if err != nil {
		return nil, fail(storeUnavailable, "The org providers could not be read: %v", err)
	}
	if object == nil {
		return nil, nil
	}
	var stored orgProviderStored
	if err := json.Unmarshal(object.Data, &stored); err != nil || stored.ID != id {
		return nil, nil
	}
	return &keptProvider{p: stored.OrgProvider, removed: stored.Removed != nil, rev: object.ETag}, nil
}

// readOrgProviders is every org provider, removed ones too, in their order.
func (si *signIns) readOrgProviders(ctx context.Context) ([]keptProvider, error) {
	keys, err := si.s.cfg.Store.List(ctx, orgProvidersPrefix)
	if err != nil {
		return nil, fail(storeUnavailable, "The org providers could not be read: %v", err)
	}
	out := []keptProvider{}
	for _, k := range keys {
		id := strings.TrimPrefix(k.Key, orgProvidersPrefix)
		if strings.HasSuffix(id, orgProviderSecret) || !strings.HasSuffix(id, ".json") {
			continue
		}
		kept, err := si.readOrgProvider(ctx, strings.TrimSuffix(id, ".json"))
		if err != nil {
			return nil, err
		}
		if kept != nil {
			out = append(out, *kept)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if a, b := deref(out[i].p.Order), deref(out[j].p.Order); a != b {
			return a < b
		}
		return out[i].p.Name < out[j].p.Name
	})
	return out, nil
}

// orgProvidersOn is every org provider turned on, in order.
func (si *signIns) orgProvidersOn(ctx context.Context) []wire.OrgProvider {
	all, err := si.readOrgProviders(ctx)
	if err != nil {
		return nil
	}
	out := []wire.OrgProvider{}
	for _, k := range all {
		if !k.removed && deref(k.p.On) {
			out = append(out, k.p)
		}
	}
	return out
}

// orgProviderOn is one org provider that is on, or a refusal in words.
func (si *signIns) orgProviderOn(ctx context.Context, id string) (*wire.OrgProvider, error) {
	kept, err := si.readOrgProvider(ctx, id)
	if err != nil {
		return nil, err
	}
	if kept == nil || kept.removed {
		return nil, fail(invalidParams, "There is no sign-in provider called %q.", id)
	}
	if !deref(kept.p.On) {
		return nil, fail(notPermitted, "Sign-in with %s is not turned on for this control plane.", kept.p.Name)
	}
	return &kept.p, nil
}

// orgRows are signIn/providers' orgProviders: id, name and order, for every client
// (FR-003).
func (si *signIns) orgRows(ctx context.Context) []wire.SignInOrgProvider {
	out := []wire.SignInOrgProvider{}
	for _, p := range si.orgProvidersOn(ctx) {
		out = append(out, wire.SignInOrgProvider{ID: p.ID, Name: p.Name, Order: deref(p.Order)})
	}
	return out
}

// isOrgProvider says a sign-in's provider is an org provider's id: neither built in nor
// the local owner's or an invite's.
func isOrgProvider(provider string) bool {
	return !outsideProvider(provider) && provider != records.ProviderLocal && provider != records.ProviderCode &&
		orgProviderIDPattern.MatchString(provider)
}

// checker is the ID-token checker of an org provider, kept while its issuer, client and
// JWKS stay the same.
func (si *signIns) checker(p wire.OrgProvider, d *signin.Discovery) *signin.OIDC {
	si.org.mu.Lock()
	defer si.org.mu.Unlock()
	if si.org.checkers == nil {
		si.org.checkers = map[string]*signin.OIDC{}
	}
	o := si.org.checkers[p.ID]
	if o == nil || o.JWKSURL != d.JWKSURI || !slices.Equal(o.Audiences, []string{p.ClientID}) || o.Issuers[0] != p.Issuer {
		o = &signin.OIDC{Provider: p.ID, Name: p.Name, Issuers: []string{p.Issuer}, Audiences: []string{p.ClientID},
			JWKSURL: d.JWKSURI, HTTP: si.cfg.HTTP, Algs: []string{"RS256", "ES256"}, Now: si.clock}
		si.org.checkers[p.ID] = o
	}
	o.Name = p.Name
	return o
}

func (si *signIns) discovery(ctx context.Context, p wire.OrgProvider, again bool) (*signin.Discovery, error) {
	si.org.discoveries.HTTP = si.cfg.HTTP
	return si.org.discoveries.Get(ctx, p.Issuer, p.Name, again)
}

// MARK: Sealing

// sealTo writes plain sealed with the keeper, bound to key, under condition when.
func (si *signIns) sealTo(ctx context.Context, key string, plain []byte, when store.Condition) (string, error) {
	sealed, err := si.s.users.SealFor(ctx, plain, []byte(key))
	if err != nil {
		return "", err
	}
	data, err := records.Encode(sealedRecord{ID: key, Sealed: sealed})
	if err != nil {
		return "", err
	}
	return si.s.cfg.Store.Put(ctx, key, data, when)
}

// openSecret is an org provider's client secret, here only (D4).
func (si *signIns) openSecret(ctx context.Context, id string) (string, error) {
	key := orgProviderSecretKey(id)
	object, err := si.s.cfg.Store.Get(ctx, key)
	if err != nil || object == nil {
		return "", errors.New("no secret")
	}
	var record sealedRecord
	if err := json.Unmarshal(object.Data, &record); err != nil || record.Sealed == nil {
		return "", errors.New("not a sealed envelope")
	}
	plain, err := si.s.users.OpenFor(ctx, record.Sealed, []byte(key))
	if err != nil {
		return "", err
	}
	return string(plain), nil
}

// fingerprint is a secret's first 8 hex of SHA-256 (D4, T6 D14).
func fingerprint(secret string) string {
	sum := sha256.Sum256([]byte(secret))
	return hex.EncodeToString(sum[:4])
}

// MARK: signIn/orgProviders/*

// orgIDFrom is an id made from a provider's name: acme-okta.
func orgIDFrom(name string) string {
	var b strings.Builder
	dash := false
	for _, r := range strings.ToLower(name) {
		switch {
		case r >= 'a' && r <= 'z' || r >= '0' && r <= '9':
			b.WriteRune(r)
			dash = false
		case !dash && b.Len() > 0:
			b.WriteByte('-')
			dash = true
		}
	}
	id := strings.Trim(b.String(), "-")
	if len(id) > 32 {
		id = strings.Trim(id[:32], "-")
	}
	if len(id) < 2 {
		id = "org-" + id
	}
	return id
}

// cleanOrgProvider checks and fills what an admin sent (data-model.md).
func cleanOrgProvider(p wire.OrgProvider) (wire.OrgProvider, error) {
	p.Name = strings.TrimSpace(p.Name)
	if n := len([]rune(p.Name)); n < 1 || n > 40 {
		return p, fail(invalidParams, "Name the provider in 1 to 40 characters.")
	}
	if p.ID == "" {
		p.ID = orgIDFrom(p.Name)
	}
	if !orgProviderIDPattern.MatchString(p.ID) || !isOrgProvider(p.ID) {
		return p, fail(invalidParams, "%q cannot be an org provider's id: use 2 to 32 of a-z, 0-9 and -.", p.ID)
	}
	switch p.Preset {
	case wire.OrgProviderPresetOkta, wire.OrgProviderPresetEntra, wire.OrgProviderPresetGoogleWorkspace, wire.OrgProviderPresetOidc:
	default:
		return p, fail(invalidParams, "Say the preset: okta, entra, googleWorkspace or oidc.")
	}
	p.Issuer = strings.TrimSuffix(strings.TrimSpace(p.Issuer), "/")
	if u, err := url.Parse(p.Issuer); err != nil || u.Scheme != "https" || u.Host == "" || u.RawQuery != "" || u.Fragment != "" || len(p.Issuer) > 300 {
		return p, fail(invalidParams, "The issuer must be an https address, such as https://acme.okta.com.")
	}
	p.ClientID = strings.TrimSpace(p.ClientID)
	if p.ClientID == "" || len(p.ClientID) > 200 {
		return p, fail(invalidParams, "Give the client id the provider made for this control plane.")
	}
	claim := strings.TrimSpace(deref(p.AccountClaim))
	if claim == "" {
		claim = "sub"
		if p.Preset == wire.OrgProviderPresetEntra {
			claim = "oid"
		}
	}
	if !claimPattern.MatchString(claim) {
		return p, fail(invalidParams, "%q is not a claim's name.", claim)
	}
	p.AccountClaim = &claim
	if tenant := strings.TrimSpace(deref(p.Tenant)); tenant != "" {
		if !claimPattern.MatchString(tenant) {
			return p, fail(invalidParams, "%q is not a tenant id.", tenant)
		}
		p.Tenant = &tenant
	} else if p.Preset == wire.OrgProviderPresetEntra {
		// https://login.microsoftonline.com/<tenant id>/v2.0 names the tenant.
		parts := strings.Split(strings.TrimPrefix(p.Issuer, "https://"), "/")
		if len(parts) < 2 || !claimPattern.MatchString(parts[1]) {
			return p, fail(invalidParams, "An Entra issuer is https://login.microsoftonline.com/<tenant id>/v2.0.")
		}
		p.Tenant = &parts[1]
	} else {
		p.Tenant = nil
	}
	scopes := []string{"openid"}
	for _, s := range p.Scopes {
		s = strings.TrimSpace(s)
		if s == "" || slices.Contains(scopes, s) {
			continue
		}
		if !scopePattern.MatchString(s) {
			return p, fail(invalidParams, "%q is not a scope.", s)
		}
		scopes = append(scopes, s)
	}
	if len(scopes) == 1 {
		scopes = append(scopes, "email", "profile")
	}
	if len(scopes) > 20 {
		return p, fail(invalidParams, "Ask for 20 scopes at most.")
	}
	p.Scopes = scopes
	join := deref(p.Join)
	switch join {
	case "":
		join = wire.OrgProviderJoinInvite
	case wire.OrgProviderJoinScim, wire.OrgProviderJoinAnyone, wire.OrgProviderJoinInvite:
	default:
		return p, fail(invalidParams, "Who may join is scim, anyone or invite.")
	}
	p.Join = &join
	if p.On == nil {
		p.On = new(true)
	}
	if p.Order == nil {
		p.Order = new(int64(0))
	}
	return p, nil
}

// setOrgProvider is signIn/orgProviders/set (FR-001 to FR-004).
func (si *signIns) setOrgProvider(ctx context.Context, set wire.OrgProviderSet, actor wire.AuditActor) (wire.OrgProviderKept, error) {
	if !si.s.users.Sealing() {
		return wire.OrgProviderKept{}, fail(orgProviderUnavailable, "An org provider needs a keeper for secrets on this control plane, to keep its client secret sealed.")
	}
	if _, ok := si.httpsBase(); !ok {
		return wire.OrgProviderKept{}, fail(orgProviderUnavailable, "An org provider needs this control plane's HTTPS address.")
	}
	p, err := cleanOrgProvider(set.Provider)
	if err != nil {
		return wire.OrgProviderKept{}, err
	}
	kept, err := si.readOrgProvider(ctx, p.ID)
	if err != nil {
		return wire.OrgProviderKept{}, err
	}
	switch {
	case kept != nil && kept.removed:
		return wire.OrgProviderKept{}, fail(invalidParams, "%q was a provider that was removed. Choose another id.", p.ID)
	case kept == nil && set.Rev != nil, kept != nil && deref(set.Rev) != kept.rev:
		return wire.OrgProviderKept{}, fail(changedElsewhere, "This provider was changed elsewhere. Read it again.")
	}
	secret := strings.TrimSpace(deref(set.Secret))
	if kept == nil && secret == "" {
		return wire.OrgProviderKept{}, fail(invalidParams, "Give the client secret the provider made for this control plane.")
	}
	if len(secret) > 1000 {
		return wire.OrgProviderKept{}, fail(invalidParams, "That client secret is too long.")
	}
	if kept == nil {
		all, err := si.readOrgProviders(ctx)
		if err != nil {
			return wire.OrgProviderKept{}, err
		}
		live := 0
		for _, k := range all {
			if !k.removed {
				live++
			}
		}
		if live >= mostOrgProviders {
			return wire.OrgProviderKept{}, fail(invalidParams, "A control plane has %d org providers at most.", mostOrgProviders)
		}
	}
	// FR-004: the issuer must do the code flow with PKCE S256.
	d, err := si.discovery(ctx, p, true)
	if err != nil {
		return wire.OrgProviderKept{}, fail(orgProviderUnavailable, "%s", err.Error())
	}
	if missing := d.Missing(p.Issuer); len(missing) > 0 {
		return wire.OrgProviderKept{}, fail(orgProviderUnavailable, "%s's discovery document lacks %s.", p.Name, strings.Join(missing, "; "))
	}
	now := records.At(si.clock())
	stamp := &wire.OrgRouteStamp{By: actor, At: wire.DateOf(now.Time)}
	p.Created, p.Changed, p.Version, p.RedirectURI, p.Scim = stamp, stamp, new(int64(1)), nil, nil
	if kept != nil {
		// SCIM is changed by scim/set only.
		p.Created, p.Secret, p.Scim = kept.p.Created, kept.p.Secret, kept.p.Scim
		p.Version = new(deref(kept.p.Version) + 1)
	}
	var restore func()
	if secret != "" {
		key := orgProviderSecretKey(p.ID)
		previous, _ := si.s.cfg.Store.Get(ctx, key)
		when := store.Absent
		if previous != nil {
			when = store.Matching(previous.ETag)
		}
		written, err := si.sealTo(ctx, key, []byte(secret), when)
		if err != nil {
			if store.IsConflict(err) {
				return wire.OrgProviderKept{}, fail(changedElsewhere, "This provider was changed elsewhere. Read it again.")
			}
			return wire.OrgProviderKept{}, userFailure(err)
		}
		restore = func() {
			if previous == nil {
				si.s.cfg.Store.Delete(context.Background(), key)
			} else {
				si.s.cfg.Store.Put(context.Background(), key, previous.Data, store.Matching(written))
			}
		}
		p.Secret = &wire.OrgProviderSecret{Fingerprint: fingerprint(secret), SetBy: &actor, SetAt: wire.DateOf(now.Time)}
	}
	data, err := records.Encode(orgProviderStored{OrgProvider: p})
	if err != nil {
		return wire.OrgProviderKept{}, err
	}
	when := store.Absent
	if kept != nil {
		when = store.Matching(kept.rev)
	}
	rev, err := si.s.cfg.Store.Put(ctx, orgProviderKey(p.ID), data, when)
	if err != nil {
		if restore != nil {
			restore()
		}
		if store.IsConflict(err) {
			return wire.OrgProviderKept{}, fail(changedElsewhere, "This provider was changed elsewhere. Read it again.")
		}
		return wire.OrgProviderKept{}, fail(storeUnavailable, "The provider could not be kept: %v", err)
	}
	var before *wire.OrgProvider
	if kept != nil {
		before = &kept.p
	}
	si.auditOrg(actor, "signIn/orgProviders/set", p.ID, providerChanges(before, p, secret))
	si.s.log(fmt.Sprintf("org provider %s is now version %d", p.ID, deref(p.Version)))
	si.s.peopleChanged("", false)
	p.RedirectURI = new(si.redirectURI())
	return wire.OrgProviderKept{Provider: p, Rev: rev}, nil
}

// providerChanges says which fields an admin changed, for the audit: never the secret,
// only that it was replaced and its fingerprint (FR-025).
func providerChanges(before *wire.OrgProvider, after wire.OrgProvider, secret string) string {
	if before == nil {
		return "added " + after.Name + " (" + after.Issuer + "), secret " + fingerprint(secret)
	}
	changed := []string{}
	add := func(name string, same bool) {
		if !same {
			changed = append(changed, name)
		}
	}
	add("name", before.Name == after.Name)
	add("issuer", before.Issuer == after.Issuer)
	add("client id", before.ClientID == after.ClientID)
	add("account claim", deref(before.AccountClaim) == deref(after.AccountClaim))
	add("tenant", deref(before.Tenant) == deref(after.Tenant))
	add("scopes", slices.Equal(before.Scopes, after.Scopes))
	add("who may join", deref(before.Join) == deref(after.Join))
	add("on", deref(before.On) == deref(after.On))
	add("order", deref(before.Order) == deref(after.Order))
	if secret != "" {
		changed = append(changed, "secret replaced ("+fingerprint(secret)+")")
	}
	if len(changed) == 0 {
		return "nothing changed"
	}
	return strings.Join(changed, ", ")
}

// removeOrgProvider is signIn/orgProviders/remove (FR-009): its secret goes, and its
// record stays as a tombstone. Its sign-ins stay on their people, and match nothing new;
// its domain claims go.
func (si *signIns) removeOrgProvider(ctx context.Context, r wire.OrgProviderRequest, actor wire.AuditActor) error {
	kept, err := si.readOrgProvider(ctx, r.ID)
	if err != nil {
		return err
	}
	if kept == nil || kept.removed {
		return fail(invalidParams, "There is no org provider called %q.", r.ID)
	}
	if r.Rev != nil && *r.Rev != kept.rev {
		return fail(changedElsewhere, "This provider was changed elsewhere. Read it again.")
	}
	now := records.At(si.clock())
	data, err := records.Encode(orgProviderStored{OrgProvider: wire.OrgProvider{ID: kept.p.ID, Name: kept.p.Name, Preset: kept.p.Preset,
		Issuer: kept.p.Issuer, ClientID: kept.p.ClientID}, Removed: &now})
	if err != nil {
		return err
	}
	if _, err := si.s.cfg.Store.Put(ctx, orgProviderKey(r.ID), data, store.Matching(kept.rev)); err != nil {
		if store.IsConflict(err) {
			return fail(changedElsewhere, "This provider was changed elsewhere. Read it again.")
		}
		return fail(storeUnavailable, "The provider could not be removed: %v", err)
	}
	if err := si.s.cfg.Store.Delete(ctx, orgProviderSecretKey(r.ID)); err != nil {
		si.s.log("org provider " + r.ID + ": its secret could not be deleted: " + err.Error())
	}
	for _, c := range si.domainClaims(ctx, true) {
		if c.claim.Provider == r.ID {
			si.s.cfg.Store.Delete(ctx, domainKey(c.claim.Domain))
		}
	}
	si.forgetClaims()
	si.auditOrg(actor, "signIn/orgProviders/remove", r.ID, kept.p.Name)
	si.s.log("org provider " + r.ID + " was removed by " + actor.User)
	si.s.peopleChanged("", false)
	return nil
}

// checkOrgProvider is signIn/orgProviders/check (FR-004): the discovery document and
// the JWKS, read again.
func (si *signIns) checkOrgProvider(ctx context.Context, r wire.OrgProviderRequest, actor wire.AuditActor) (wire.OrgProviderCheck, error) {
	kept, err := si.readOrgProvider(ctx, r.ID)
	if err != nil {
		return wire.OrgProviderCheck{}, err
	}
	if kept == nil || kept.removed {
		return wire.OrgProviderCheck{}, fail(invalidParams, "There is no org provider called %q.", r.ID)
	}
	out := wire.OrgProviderCheck{Missing: []string{}, RedirectURI: si.redirectURI()}
	d, err := si.discovery(ctx, kept.p, true)
	if err != nil {
		out.Missing = append(out.Missing, err.Error())
	} else {
		out.Missing = d.Missing(kept.p.Issuer)
		n, err := si.checker(kept.p, d).Keys(ctx)
		if err != nil {
			out.Missing = append(out.Missing, err.Error())
		}
		out.JwksKeys = int64(n)
	}
	out.Ok = len(out.Missing) == 0 && out.JwksKeys > 0
	result := "answered"
	if !out.Ok {
		result = "did not answer: " + strings.Join(out.Missing, "; ")
	}
	si.auditOrg(actor, "signIn/orgProviders/check", r.ID, result)
	return out, nil
}

func (si *signIns) listOrgProviders(ctx context.Context) (wire.OrgProviderList, error) {
	all, err := si.readOrgProviders(ctx)
	if err != nil {
		return wire.OrgProviderList{}, err
	}
	out := wire.OrgProviderList{Providers: []wire.OrgProviderKept{}}
	for _, k := range all {
		if k.removed {
			continue
		}
		k.p.RedirectURI = new(si.redirectURI())
		out.Providers = append(out.Providers, wire.OrgProviderKept{Provider: k.p, Rev: k.rev})
	}
	return out, nil
}

// MARK: signIn/orgStart and signIn/ticket

// orgStart is signIn/orgStart (FR-005): a state for this connection, and the address that
// sends the browser to the provider.
func (si *signIns) orgStart(ctx context.Context, start wire.SignInOrgStart, b binding) (wire.SignInOrgStarted, error) {
	base, ok := si.httpsBase()
	if !ok {
		return wire.SignInOrgStarted{}, fail(orgProviderUnavailable, "An org provider needs this control plane's HTTPS address.")
	}
	switch {
	case start.Purpose == wire.SignInOrgPurposePair && b.hello == nil:
		return wire.SignInOrgStarted{}, fail(invalidParams, "This client is paired already: add the sign-in with purpose addToMe.")
	case start.Purpose == wire.SignInOrgPurposeAddToMe && b.hello != nil:
		return wire.SignInOrgStarted{}, fail(invalidParams, "Pair first, then add the sign-in.")
	case start.Purpose != wire.SignInOrgPurposePair && start.Purpose != wire.SignInOrgPurposeAddToMe:
		return wire.SignInOrgStarted{}, fail(invalidParams, "Say the purpose: pair or addToMe.")
	case start.ReturnTo != wire.SignInOrgReturnApp && start.ReturnTo != wire.SignInOrgReturnWeb:
		return wire.SignInOrgStarted{}, fail(invalidParams, "Say where the browser comes back: app or web.")
	}
	p, err := si.orgProviderOn(ctx, start.Provider)
	if err != nil {
		return wire.SignInOrgStarted{}, err
	}
	if _, err := si.discovery(ctx, *p, false); err != nil {
		return wire.SignInOrgStarted{}, signInFailure(err)
	}
	hint := strings.TrimSpace(deref(start.LoginHint))
	if len(hint) > 254 {
		hint = ""
	}
	id := randomToken(16)
	key := storeKeyHash(oidcStatePrefix, id)
	secrets, _ := json.Marshal(stateSecrets{Verifier: randomToken(32), Nonce: randomToken(16)})
	sealed, err := si.s.users.SealFor(ctx, secrets, []byte(key))
	if err != nil {
		return wire.SignInOrgStarted{}, fail(notPermitted, "This control plane cannot open its secrets.")
	}
	now := si.clock()
	state := orgState{Provider: p.ID, Purpose: string(start.Purpose), ReturnTo: string(start.ReturnTo), Bind: b.to(string(start.ReturnTo)).hash(), Person: b.person,
		LoginHint: hint, Made: records.At(now), Ends: records.At(now.Add(stateLife)), Sealed: sealed}
	data, err := records.Encode(state)
	if err != nil {
		return wire.SignInOrgStarted{}, err
	}
	if _, err := si.s.cfg.Store.Put(ctx, key+".json", data, store.Absent); err != nil {
		return wire.SignInOrgStarted{}, fail(storeUnavailable, "The sign-in could not be started: %v", err)
	}
	return wire.SignInOrgStarted{URL: base + "/v1/oidc/start?s=" + url.QueryEscape(id)}, nil
}

// spend marks a state or a ticket used: create-only, so of two copies one wins (D3).
func (si *signIns) spend(ctx context.Context, key string) error {
	now := records.At(si.clock())
	data, _ := records.Encode(map[string]any{"used": now})
	_, err := si.s.cfg.Store.Put(ctx, key+usedSuffix, data, store.Absent)
	return err
}

func (si *signIns) readTicket(ctx context.Context, ticket string) (*orgTicket, string, error) {
	key := storeKeyHash(oidcTicketPrefix, ticket)
	object, err := si.s.cfg.Store.Get(ctx, key+".json")
	if err != nil {
		return nil, "", fail(storeUnavailable, "The sign-in could not be read: %v", err)
	}
	if object == nil {
		return nil, "", fail(notPermitted, "That sign-in is not known here. Sign in again.")
	}
	var t orgTicket
	if json.Unmarshal(object.Data, &t) != nil {
		return nil, "", fail(notPermitted, "That sign-in is not known here. Sign in again.")
	}
	t.key = key
	return &t, key, nil
}

// takeTicket checks a ticket against the connection that holds it, and spends it. A
// ticket shown on another connection, or late, is refused and not spent, so it pairs
// nothing and writes nothing (SC-004).
func (si *signIns) takeTicket(ctx context.Context, ticket string, b binding, purpose wire.SignInOrgPurpose, accept func(*orgTicket) error) (*orgTicket, error) {
	if len(ticket) < 16 || len(ticket) > 64 {
		return nil, fail(notPermitted, "That sign-in is not known here. Sign in again.")
	}
	t, key, err := si.readTicket(ctx, ticket)
	if err != nil {
		return nil, err
	}
	if t.Bind != b.to(t.ReturnTo).hash() || t.Purpose != string(purpose) {
		return nil, fail(notPermitted, "That sign-in was made for another connection. Sign in again on this one.")
	}
	if !si.clock().Before(t.Ends.Time) {
		return nil, fail(notPermitted, "That sign-in took more than 2 minutes to come back. Sign in again.")
	}
	if accept != nil {
		if err := accept(t); err != nil {
			return nil, err
		}
	}
	if err := si.spend(ctx, key); err != nil {
		if store.IsConflict(err) {
			return nil, fail(notPermitted, "That sign-in was used already. Sign in again.")
		}
		return nil, fail(storeUnavailable, "The sign-in could not be kept: %v", err)
	}
	if _, err := si.orgProviderOn(ctx, t.Provider); err != nil {
		return nil, err
	}
	return t, nil
}

// ticketPair is signIn/ticket on an s: connection (FR-006, FR-008): it pairs the
// connection as the ticket's person, or makes them by Who may join.
func (si *signIns) ticketPair(ctx context.Context, client string, public, helloNonce []byte, r wire.SignInTicket) (*wire.SignInTicketResult, error) {
	name := strings.TrimSpace(deref(r.Name))
	kind := string(deref(r.Kind))
	if name == "" || len([]rune(name)) > 80 {
		return nil, fail(invalidParams, "Say the client's name.")
	}
	t, err := si.takeTicket(ctx, r.Ticket, binding{hello: helloNonce, client: client, public: public}, wire.SignInOrgPurposePair, func(t *orgTicket) error {
		switch {
		case kind == records.KindMac || kind == records.KindIPhone || kind == records.KindIPad:
		case kind == records.KindBrowser && t.ReturnTo == string(wire.SignInOrgReturnWeb):
		default:
			return fail(invalidParams, "That kind of client pairs elsewhere.")
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	p, err := si.orgProviderOn(ctx, t.Provider)
	if err != nil {
		return nil, err
	}
	person, err := si.personWithSignIn(ctx, t.Provider, t.Account)
	if err != nil {
		return nil, err
	}
	// A person SCIM made, signing in for the first time (FR-016).
	if person == nil {
		if person, err = si.matchProvisioned(ctx, t.Provider, t.Account, t.Email); err != nil {
			return nil, err
		}
	}
	joined := false
	if person == nil {
		if deref(p.Join) == wire.OrgProviderJoinScim && p.Scim != nil && p.Scim.On {
			si.auditSignIn(t, "", "signIn/ticket", "refused: not provisioned by SCIM")
			return nil, fail(notPermitted, "%s has not added you to this control plane yet. Ask your IT team to assign you the app, or ask an admin for an invite.", p.Name)
		}
		if deref(p.Join) != wire.OrgProviderJoinAnyone {
			si.auditSignIn(t, "", "signIn/ticket", "refused: needs an invite")
			return nil, fail(notPermitted, "Ask an admin of this control plane for an invite. Pair with its code, then add Sign in with %s under Account.", p.Name)
		}
		id, err := si.joinByOrg(ctx, t)
		if err != nil {
			return nil, err
		}
		person, joined = si.s.records.Person(id), true
	}
	if person == nil || person.IsRemoved() {
		return nil, fail(notPermitted, "This person was removed from the control plane. Ask an admin for a new invite.")
	}
	if person.IsBot() {
		return nil, fail(notPermitted, "A bot does not sign in.")
	}
	if person.IsSuspended() {
		si.auditSignIn(t, person.ID, "signIn/ticket", "refused: suspended")
		return nil, fail(personSuspended, "Your organisation's sign-in turned your access off.")
	}
	owner := person.ID
	record := records.ClientRecord{ID: client, Name: name, Kind: kind, PublicKey: public, Paired: records.Now(), Owner: &owner,
		Expires: si.s.newExpiry()}
	if err := si.s.methods.Admit(ctx, record); err != nil {
		return nil, err
	}
	what := "paired " + name
	if joined {
		what = "joined, and paired " + name
	}
	si.auditSignIn(t, owner, "signIn/ticket", what)
	si.keepRefresh(ctx, t, owner)
	si.s.log(name + " paired (" + kind + ") by signing in with org provider " + p.ID + " as person " + owner)
	si.s.announce("clientPaired", client, "signin")
	return &wire.SignInTicketResult{Client: new(wire.UUID(client))}, nil
}

// joinByOrg makes a member for an org sign-in (D10 Anyone the provider signs in): the
// same id at every copy, so two copies make one person.
func (si *signIns) joinByOrg(ctx context.Context, t *orgTicket) (string, error) {
	id := personIDForSignIn(t.Provider, t.Account)
	name := t.Name
	if name == "" {
		name, _, _ = strings.Cut(t.Email, "@")
	}
	if name == "" {
		name = "Member"
	}
	now := records.Now()
	in := records.SignIn{Provider: t.Provider, Account: t.Account, Email: t.Email, Added: &now}
	err := si.s.records.ChangePeople(ctx, func(all map[string]records.Person) ([]records.Person, error) {
		if _, there := all[id]; there {
			return nil, nil
		}
		for _, p := range all {
			if p.HasSignIn(t.Provider, t.Account) {
				return nil, fail(notPermitted, "That account is already another person's sign-in.")
			}
		}
		return []records.Person{{ID: id, Name: name, Kind: records.KindPerson, Role: records.RoleMember, SignIns: []records.SignIn{in}}}, nil
	})
	if err != nil {
		return "", err
	}
	si.s.peopleChanged(id, false)
	si.s.log("person " + id + " joined by signing in with org provider " + t.Provider)
	return id, nil
}

// ticketAdd is signIn/ticket on a paired client's connection: the org sign-in becomes one
// more of the caller's (US2 AS6).
func (si *signIns) ticketAdd(ctx context.Context, r wire.SignInTicket, from Caller, user string) (*wire.SignInTicketResult, error) {
	t, err := si.takeTicket(ctx, r.Ticket, binding{session: from.Session, person: user, client: from.Client}, wire.SignInOrgPurposeAddToMe, nil)
	if err != nil {
		return nil, err
	}
	now := records.Now()
	in := records.SignIn{Provider: t.Provider, Account: t.Account, Email: t.Email, Added: &now}
	err = si.s.records.ChangePeople(ctx, func(all map[string]records.Person) ([]records.Person, error) {
		me, ok := all[user]
		if !ok || me.IsRemoved() || me.IsBot() {
			return nil, fail(notPermitted, "This client's person cannot add a sign-in.")
		}
		if me.IsSuspended() {
			return nil, fail(personSuspended, "Your organisation's sign-in turned your access off.")
		}
		for _, p := range all {
			if p.HasSignIn(t.Provider, t.Account) {
				if p.ID == user {
					return nil, nil
				}
				return nil, fail(notPermitted, "That account is already another person's sign-in.")
			}
		}
		me.SignIns = append(me.SignIns, in)
		return []records.Person{me}, nil
	})
	if err != nil {
		return nil, err
	}
	si.auditSignIn(t, user, "signIn/ticket", "added the sign-in")
	si.keepRefresh(ctx, t, user)
	si.s.peopleChanged(user, false)
	si.s.log("person " + user + " added a sign-in with org provider " + t.Provider)
	out := wire.SignIn{Provider: t.Provider, Account: &t.Account, Email: optional(t.Email)}
	return &wire.SignInTicketResult{SignIn: &out}, nil
}

// MARK: Audit

// orgSelfAudited are the methods that write their own entry, with what changed and never
// a secret, so the router does not write one from their params (FR-025).
var orgSelfAudited = methodSet("signIn/domains/check", "signIn/domains/claim", "signIn/domains/remove", "signIn/domains/set",
	"signIn/orgProviders/check", "signIn/orgProviders/remove", "signIn/orgProviders/set", "signIn/ticket",
	"groups/setRole", "scim/set", "scim/tokens/make", "scim/tokens/revoke")

func (si *signIns) auditOrg(actor wire.AuditActor, method, id, what string) {
	action, ok := audit.Action(method, false)
	if !ok {
		return
	}
	target := id
	if what != "" {
		target += ": " + what
	}
	if len(target) > 300 {
		target = target[:300] + "…"
	}
	si.s.auditTo(actor, method, action, target)
}

// auditSignIn keeps an org sign-in: who, by which provider, and what it did. The actor is
// the person when known, or the provider's account.
func (si *signIns) auditSignIn(t *orgTicket, person, method, what string) {
	actor := wire.AuditActor{User: person}
	if person == "" {
		actor.User = t.Provider + ":" + t.Account
	} else if name := si.s.personName(person); name != "" {
		actor.UserName = &name
	}
	target := t.Provider
	if t.Email != "" {
		target += " (" + t.Email + ")"
	}
	si.auditOrg(actor, method, target, what)
}

// pkceChallenge is S256 of a PKCE verifier (RFC 7636).
func pkceChallenge(verifier string) string {
	sum := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

// orgSignInMethod answers the org methods of signIn/* on a paired client's connection
// (contracts/identity-api.md): orgStart, ticket and discover for anyone, the rest for
// admins.
func (m *Methods) orgSignInMethod(ctx context.Context, method string, params json.RawMessage, from Caller, user string) (any, error) {
	si := m.s.signIns
	switch method {
	case "signIn/orgStart":
		o, err := require[wire.SignInOrgStart](params, "SignInOrgStart")
		if err != nil {
			return nil, err
		}
		return si.orgStart(ctx, o, binding{session: from.Session, person: user, client: from.Client})
	case "signIn/ticket":
		t, err := require[wire.SignInTicket](params, "SignInTicket")
		if err != nil {
			return nil, err
		}
		return si.ticketAdd(ctx, t, from, user)
	case "signIn/discover":
		d, err := require[wire.SignInDiscover](params, "SignInDiscover")
		if err != nil {
			return nil, err
		}
		return si.discover(ctx, d), nil
	}
	if !strings.HasPrefix(method, "signIn/orgProviders/") && !strings.HasPrefix(method, "signIn/domains/") {
		return nil, fail(methodNotFound, "%s", method)
	}
	if !m.s.isAdmin(user) {
		return nil, fail(notPermitted, "Only an admin changes how people sign in.")
	}
	actor := m.s.actorFor(from.Client)
	switch method {
	case "signIn/orgProviders/list":
		return si.listOrgProviders(ctx)
	case "signIn/orgProviders/set":
		set, err := require[wire.OrgProviderSet](params, "OrgProviderSet")
		if err != nil {
			return nil, err
		}
		return si.setOrgProvider(ctx, set, actor)
	case "signIn/orgProviders/check", "signIn/orgProviders/remove":
		r, err := require[wire.OrgProviderRequest](params, "OrgProviderRequest")
		if err != nil {
			return nil, err
		}
		if method == "signIn/orgProviders/check" {
			return si.checkOrgProvider(ctx, r, actor)
		}
		return map[string]any{}, si.removeOrgProvider(ctx, r, actor)
	case "signIn/domains/list":
		return si.listDomains(ctx), nil
	case "signIn/domains/claim":
		r, err := require[wire.SignInDomainClaim](params, "SignInDomainClaim")
		if err != nil {
			return nil, err
		}
		return si.claimDomain(ctx, r, actor)
	case "signIn/domains/set":
		r, err := require[wire.SignInDomainSet](params, "SignInDomainSet")
		if err != nil {
			return nil, err
		}
		return si.setDomain(ctx, r, actor)
	case "signIn/domains/check", "signIn/domains/preview", "signIn/domains/remove":
		r, err := require[wire.SignInDomainRequest](params, "SignInDomainRequest")
		if err != nil {
			return nil, err
		}
		switch method {
		case "signIn/domains/check":
			domain, err := cleanDomain(r.Domain)
			if err != nil {
				return nil, err
			}
			k, err := si.readClaim(ctx, domain)
			if err != nil {
				return nil, err
			}
			if k == nil {
				return nil, fail(invalidParams, "%s is not claimed.", domain)
			}
			return si.checkClaim(ctx, *k, actor)
		case "signIn/domains/preview":
			return si.previewDomain(ctx, r)
		}
		return map[string]any{}, si.removeDomain(ctx, r, actor)
	}
	return nil, fail(methodNotFound, "%s", method)
}
