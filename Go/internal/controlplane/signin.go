package controlplane

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/signin"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Sign-in with Google, Apple and GitHub (#995, spec 736 T2). A client with no code dials
// as s:<its UUID> with the key it will keep, proves that key as a paired client does, and
// then, on that connection, signs in: an ID token whose nonce it made from this control
// plane's key id and the hello's nonce (Google, Apple), or a GitHub user token. A person
// already known pairs at once, except by GitHub, which waits for Approve on another of
// the person's clients (R3). A person not known joins only by an allowed Google Workspace
// domain; anyone else is invited first, pairs with the code, and adds the sign-in from
// that client (signIn/addToMe). No token is kept, written or logged.

// signInKey is v1/signin.json: which providers an admin turned on, and what they allow.
const signInKey = "v1/signin.json"

type signInSettings struct {
	Google struct {
		On      bool     `json:"on,omitempty"`
		Domains []string `json:"allowedDomains,omitempty"`
	} `json:"google"`
	Apple struct {
		On bool `json:"on,omitempty"`
	} `json:"apple"`
	GitHub struct {
		On   bool     `json:"on,omitempty"`
		Orgs []string `json:"allowedOrgs,omitempty"`
	} `json:"github"`
}

func (s signInSettings) on(provider string) bool {
	switch provider {
	case signin.Google:
		return s.Google.On
	case signin.Apple:
		return s.Apple.On
	case signin.GitHub:
		return s.GitHub.On
	}
	return false
}

const (
	// signInWait is how long an s: connection may stay open: long enough for a person to
	// sign in with their provider, and for a GitHub sign-in to be approved.
	signInWait = 10 * time.Minute
	// At most this many s: connections at once at this copy, and from one address.
	signInsOpen      = 50
	signInsPerSource = 5
	// challengeLife is how long a paired client's challenge for signIn/addToMe lasts.
	challengeLife = 10 * time.Minute
)

// signIns is the service's sign-in state at this copy.
type signIns struct {
	s   *Service
	cfg signin.Config
	// The checkers, made once so each keeps its JWKS.
	oidc   map[string]*signin.OIDC
	github *signin.GitHubAPI

	mu sync.Mutex
	// Open s: connections, by source address (an IPv6 /64 as one), oldest first.
	open map[string][]*Conn
	// Each paired session's challenge for signIn/addToMe, used once.
	challenges map[string]challenge
	// Org providers and claimed domains (#1002).
	org orgBits
}

type challenge struct {
	value   []byte
	expires time.Time
}

func newSignIns(s *Service, cfg *signin.Config) *signIns {
	c := signin.FromEnvironment()
	if cfg != nil {
		c = *cfg
	}
	return &signIns{s: s, cfg: c, oidc: map[string]*signin.OIDC{signin.Google: c.OIDCFor(signin.Google), signin.Apple: c.OIDCFor(signin.Apple)},
		github: c.GitHubFor(), open: map[string][]*Conn{}, challenges: map[string]challenge{}}
}

// settings reads v1/signin.json: none is every provider off.
func (si *signIns) settings(ctx context.Context) (signInSettings, string, error) {
	var out signInSettings
	object, err := si.s.cfg.Store.Get(ctx, signInKey)
	if err != nil {
		return out, "", err
	}
	if object == nil {
		return out, "", nil
	}
	if json.Unmarshal(object.Data, &out) != nil {
		return signInSettings{}, object.ETag, nil
	}
	return out, object.ETag, nil
}

// on says a provider is turned on and this build can check it.
func (si *signIns) on(settings signInSettings, provider string) bool {
	available, _ := si.cfg.Available(provider)
	return available && settings.on(provider)
}

// providers is signIn/providers: every provider, with what an admin may see.
func (si *signIns) providers(settings signInSettings, admin bool, challengeValue []byte) wire.SignInProviders {
	out := wire.SignInProviders{Providers: []wire.SignInProvider{}}
	for _, p := range signin.Providers {
		available, why := si.cfg.Available(p)
		row := wire.SignInProvider{Provider: p, On: available && settings.on(p), Available: available}
		if !available {
			row.Why = &why
		}
		if id := si.cfg.ClientID(p); id != "" && row.On {
			row.ClientID = &id
		}
		out.Providers = append(out.Providers, row)
	}
	if challengeValue != nil {
		out.Challenge = new(controllink.B64URL(challengeValue))
	}
	if admin {
		out.Domains = append([]string{}, settings.Google.Domains...)
		out.Organisations = append([]string{}, settings.GitHub.Orgs...)
	}
	// Org providers come first on every screen (#1002, FR-026); none is no field at all.
	ctx := context.Background()
	if rows := si.orgRows(ctx); len(rows) > 0 {
		out.OrgProviders = rows
		if si.discovers(ctx) {
			out.Discover = new(true)
		}
	}
	return out
}

// keyID is this control plane's key id now, as nonces are bound to it.
func (si *signIns) keyID() string { return records.ControlKeyID(si.s.currentKeys().public) }

// checked is who a sign-in names, once checked: the provider's account and what is shown.
type checked struct {
	provider, account, email, login, name, domain string
	emailVerified                                 bool
}

// check checks a token for a provider that is on: an ID token against the nonce made from
// challengeValue, or a GitHub token against GET /user, and an allowed organisation.
func (si *signIns) check(ctx context.Context, settings signInSettings, provider, token string, challengeValue []byte) (*checked, error) {
	if !si.on(settings, provider) {
		return nil, fail(notPermitted, "Sign-in with %s is not turned on for this control plane.", signin.Title(provider))
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	switch provider {
	case signin.Google, signin.Apple:
		claims, err := si.oidc[provider].Check(ctx, token, signin.Nonce(si.keyID(), challengeValue))
		if err != nil {
			return nil, signInFailure(err)
		}
		return &checked{provider: provider, account: claims.Subject, email: claims.Email, name: claims.Name,
			domain: strings.ToLower(claims.Domain), emailVerified: claims.EmailVerified}, nil
	case signin.GitHub:
		user, err := si.github.User(ctx, token)
		if err != nil {
			return nil, signInFailure(err)
		}
		if orgs := settings.GitHub.Orgs; len(orgs) > 0 {
			in := false
			for _, org := range orgs {
				ok, err := si.github.InOrganisation(ctx, token, org)
				if err != nil {
					return nil, signInFailure(err)
				}
				if ok {
					in = true
					break
				}
			}
			if !in {
				return nil, fail(notPermitted, "GitHub user %s is not in an organisation this control plane allows (%s).", user.Login,
					strings.Join(orgs, ", "))
			}
		}
		return &checked{provider: provider, account: user.ID, login: user.Login, name: user.Name}, nil
	}
	return nil, fail(invalidParams, "There is no sign-in provider called %q.", provider)
}

// outsideProvider says a sign-in is Google's, Apple's or GitHub's.
func outsideProvider(provider string) bool { return slices.Contains(signin.Providers, provider) }

// signInFailure says a refused sign-in or an unreachable provider to the person (FR-015).
func signInFailure(err error) error {
	if signin.IsRefused(err) || signin.IsUnavailable(err) {
		return fail(notPermitted, "%s", err.Error())
	}
	return fail(notPermitted, "The sign-in could not be checked. Try again.")
}

// personWithSignIn is the person, removed or not, who signs in with that account, read
// from the store again: one added at another copy a moment ago counts.
func (si *signIns) personWithSignIn(ctx context.Context, provider, account string) (*records.Person, error) {
	var found *records.Person
	err := si.s.records.ChangePeople(ctx, func(all map[string]records.Person) ([]records.Person, error) {
		for _, p := range all {
			if p.HasSignIn(provider, account) {
				found = &p
				return nil, nil
			}
		}
		return nil, nil
	})
	if err != nil {
		return nil, fail(storeUnavailable, "The people could not be read: %v", err)
	}
	return found, nil
}

// personIDForSignIn is the person an allowed domain makes: the same at every copy, so two
// copies that sign in one account at once make one person.
func personIDForSignIn(provider, account string) string {
	sum := sha256.Sum256([]byte("agents-person-signin\x00" + provider + "\x00" + account))
	id := hex.EncodeToString(sum[:16])
	return id[0:8] + "-" + id[8:12] + "-4" + id[13:16] + "-8" + id[17:20] + "-" + id[20:32]
}

func (c *checked) signIn() records.SignIn {
	now := records.Now()
	return records.SignIn{Provider: c.provider, Account: c.account, Email: c.email, Login: c.login, Added: &now}
}

// joinByDomain makes a member of a Google Workspace account on an allowed domain (FR-006).
func (si *signIns) joinByDomain(ctx context.Context, c *checked, settings signInSettings) (string, error) {
	if c.provider != signin.Google || c.domain == "" || !c.emailVerified || !slices.Contains(settings.Google.Domains, c.domain) {
		return "", nil
	}
	id := personIDForSignIn(c.provider, c.account)
	name := c.name
	if name == "" {
		name, _, _ = strings.Cut(c.email, "@")
	}
	err := si.s.records.ChangePeople(ctx, func(all map[string]records.Person) ([]records.Person, error) {
		if _, there := all[id]; there {
			return nil, nil
		}
		for _, p := range all {
			if p.HasSignIn(c.provider, c.account) {
				return nil, fail(notPermitted, "That account is already another person's sign-in.")
			}
		}
		return []records.Person{{ID: id, Name: name, Kind: records.KindPerson, Role: records.RoleMember,
			SignIns: []records.SignIn{c.signIn()}}}, nil
	})
	if err != nil {
		return "", err
	}
	if p := si.s.records.Person(id); p == nil || p.IsRemoved() {
		return "", fail(notPermitted, "This account's person was removed. Ask an admin for a new invite.")
	}
	si.s.peopleChanged(id, false)
	si.s.log("person " + id + " joined by signing in with Google on an allowed domain")
	return id, nil
}

var (
	domainPattern = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$`)
	orgPattern    = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$`)
)

// configure is signIn/configure, for admins (FR-004, FR-006).
func (si *signIns) configure(ctx context.Context, c wire.SignInConfigure, user string) (wire.SignInProviders, error) {
	if !si.s.isAdmin(user) {
		return wire.SignInProviders{}, fail(notPermitted, "Only an admin turns sign-in providers on.")
	}
	if !slices.Contains(signin.Providers, c.Provider) {
		return wire.SignInProviders{}, fail(invalidParams, "There is no sign-in provider called %q.", c.Provider)
	}
	if c.On != nil && *c.On {
		if available, why := si.cfg.Available(c.Provider); !available {
			return wire.SignInProviders{}, fail(notPermitted, "%s", why)
		}
	}
	clean := func(in []string, pattern *regexp.Regexp, lower bool, what string) ([]string, error) {
		out := []string{}
		for _, v := range in {
			v = strings.TrimSpace(v)
			if lower {
				v = strings.ToLower(v)
			}
			if v == "" {
				continue
			}
			if !pattern.MatchString(v) || len(v) > 253 {
				return nil, fail(invalidParams, "%q is not %s.", v, what)
			}
			if !slices.Contains(out, v) {
				out = append(out, v)
			}
		}
		if len(out) > 50 {
			return nil, fail(invalidParams, "Allow 50 at most.")
		}
		return out, nil
	}
	if c.Domains != nil && c.Provider != signin.Google || c.Organisations != nil && c.Provider != signin.GitHub {
		return wire.SignInProviders{}, fail(invalidParams, "Domains are Google's, and organisations GitHub's.")
	}
	for {
		settings, etag, err := si.settings(ctx)
		if err != nil {
			return wire.SignInProviders{}, fail(storeUnavailable, "The sign-in settings could not be read: %v", err)
		}
		switch c.Provider {
		case signin.Google:
			if c.On != nil {
				settings.Google.On = *c.On
			}
			if c.Domains != nil {
				if settings.Google.Domains, err = clean(c.Domains, domainPattern, true, "a domain"); err != nil {
					return wire.SignInProviders{}, err
				}
			}
		case signin.Apple:
			if c.On != nil {
				settings.Apple.On = *c.On
			}
		case signin.GitHub:
			if c.On != nil {
				settings.GitHub.On = *c.On
			}
			if c.Organisations != nil {
				if settings.GitHub.Orgs, err = clean(c.Organisations, orgPattern, false, "a GitHub organisation"); err != nil {
					return wire.SignInProviders{}, err
				}
			}
		}
		data, err := records.Encode(settings)
		if err != nil {
			return wire.SignInProviders{}, err
		}
		condition := store.Absent
		if etag != "" {
			condition = store.Matching(etag)
		}
		if _, err := si.s.cfg.Store.Put(ctx, signInKey, data, condition); err != nil {
			if store.IsConflict(err) {
				continue
			}
			return wire.SignInProviders{}, fail(storeUnavailable, "The sign-in settings could not be kept: %v", err)
		}
		si.s.log("sign-in with " + signin.Title(c.Provider) + " was changed by " + user)
		si.s.peopleChanged("", false)
		return si.providers(settings, true, nil), nil
	}
}

// newChallenge is a paired session's challenge for signIn/addToMe: fresh, used once.
func (si *signIns) newChallenge(session string) []byte {
	value := controllink.Nonce()
	si.mu.Lock()
	defer si.mu.Unlock()
	now := time.Now()
	for k, c := range si.challenges {
		if now.After(c.expires) {
			delete(si.challenges, k)
		}
	}
	if len(si.challenges) >= 10000 {
		for k := range si.challenges {
			delete(si.challenges, k)
			break
		}
	}
	si.challenges[session] = challenge{value, now.Add(challengeLife)}
	return value
}

func (si *signIns) takeChallenge(session string) []byte {
	si.mu.Lock()
	defer si.mu.Unlock()
	c, ok := si.challenges[session]
	delete(si.challenges, session)
	if !ok || time.Now().After(c.expires) {
		return nil
	}
	return c.value
}

// addToMe is signIn/addToMe (FR-005): the sign-in becomes one more of the caller's.
func (si *signIns) addToMe(ctx context.Context, a wire.SignInAdd, from Caller, user string) (*wire.SignIn, error) {
	settings, _, err := si.settings(ctx)
	if err != nil {
		return nil, fail(storeUnavailable, "The sign-in settings could not be read: %v", err)
	}
	var value []byte
	if a.Provider != signin.GitHub {
		if value = si.takeChallenge(from.Session); value == nil {
			return nil, fail(notPermitted, "Ask signIn/providers for a challenge first, and sign in with it within 10 minutes.")
		}
	}
	c, err := si.check(ctx, settings, a.Provider, a.Token, value)
	if err != nil {
		return nil, err
	}
	if err := si.requiredFor(ctx, c.provider, c.email, user); err != nil {
		return nil, err
	}
	err = si.s.records.ChangePeople(ctx, func(all map[string]records.Person) ([]records.Person, error) {
		me, ok := all[user]
		if !ok || me.IsRemoved() || me.IsBot() {
			return nil, fail(notPermitted, "This client's person cannot add a sign-in.")
		}
		for _, p := range all {
			if p.HasSignIn(c.provider, c.account) {
				if p.ID == user {
					return nil, nil
				}
				return nil, fail(notPermitted, "That %s account is already another person's sign-in.", signin.Title(c.provider))
			}
		}
		me.SignIns = append(me.SignIns, c.signIn())
		return []records.Person{me}, nil
	})
	if err != nil {
		return nil, err
	}
	si.s.peopleChanged(user, false)
	si.s.log("person " + user + " added a sign-in with " + signin.Title(c.provider))
	in := wire.SignIn{Provider: c.provider, Account: &c.account, Email: optional(c.email), Login: optional(c.login)}
	return &in, nil
}

// removeFromMe is signIn/removeFromMe: an outside sign-in leaves the caller's person.
func (si *signIns) removeFromMe(ctx context.Context, r wire.SignInRemove, user string) error {
	if !outsideProvider(r.Provider) {
		return fail(invalidParams, "Only a Google, Apple or GitHub sign-in can be taken off.")
	}
	found := false
	err := si.s.records.ChangePeople(ctx, func(all map[string]records.Person) ([]records.Person, error) {
		me, ok := all[user]
		if !ok {
			return nil, nil
		}
		kept := []records.SignIn{}
		for _, in := range me.SignIns {
			if in.Provider == r.Provider && in.Account == r.Account {
				found = true
				continue
			}
			kept = append(kept, in)
		}
		if !found {
			return nil, nil
		}
		me.SignIns = kept
		return []records.Person{me}, nil
	})
	if err != nil {
		return err
	}
	if !found {
		return fail(invalidParams, "This person has no such sign-in.")
	}
	si.s.peopleChanged(user, false)
	si.s.log("person " + user + " took off a sign-in with " + signin.Title(r.Provider))
	return nil
}

// key is the shared key of an s: identity: the ECDH of the client's new key and the
// control plane's, as a paired client's. Refused when no provider is on, or the client
// is one already paired.
func (si *signIns) key(id controllink.Identity, public, private []byte) ([]byte, error) {
	settings, _, err := si.settings(context.Background())
	if err != nil {
		return nil, notTheirs{controllink.Refuse(controllink.Unavailable)}
	}
	if !si.anyOn(settings) && len(si.orgProvidersOn(context.Background())) == 0 || len(public) == 0 || si.s.records.Client(id.ID) != nil || si.s.records.WasForgotten(id.ID) {
		return nil, controllink.Refuse(controllink.Unknown)
	}
	key, err := controllink.ClientKey(private, public, id.ID)
	if err != nil {
		return nil, controllink.Refuse(controllink.BadMessage)
	}
	return key, nil
}

func (si *signIns) anyOn(settings signInSettings) bool {
	for _, p := range signin.Providers {
		if si.on(settings, p) {
			return true
		}
	}
	return false
}

// sourceOf is a socket's address with no port, for the per-source limit.
func sourceOf(remote string) string {
	if host, _, err := net.SplitHostPort(remote); err == nil {
		return host
	}
	return remote
}

// drop lets go of a sign-in's place; one dropped already is not there.
func (si *signIns) drop(source string, conn *Conn) {
	list := slices.DeleteFunc(si.open[source], func(c *Conn) bool { return c == conn })
	if len(list) == 0 {
		delete(si.open, source)
	} else {
		si.open[source] = list
	}
}

// pairing is an s: connection after its ok: signIn/providers, then one signIn/pair.
func (si *signIns) pairing(conn *Conn, client string, public, helloNonce []byte) {
	source := keyOf(sourceOf(conn.Remote))
	si.mu.Lock()
	total, counts := 0, map[string]int{}
	for from, list := range si.open {
		total += len(list)
		counts[from] = len(list)
	}
	var dropped *Conn
	if total >= signInsOpen && len(si.open[source]) < signInsPerSource {
		// Every place is taken: the oldest of the address that holds the most goes (#2150).
		if from := heaviest(counts); from != "" {
			dropped = si.open[from][0]
			si.drop(from, dropped)
			total--
		}
	}
	if total >= signInsOpen || len(si.open[source]) >= signInsPerSource {
		si.mu.Unlock()
		si.s.refusals.note("signin", source, "closed a sign-in from "+source+": too many are open")
		conn.Close()
		return
	}
	si.open[source] = append(si.open[source], conn)
	si.mu.Unlock()
	if dropped != nil {
		si.s.refusals.note("signin-dropped", "", "closed the oldest sign-in from "+keyOf(sourceOf(dropped.Remote))+": every place was taken")
		dropped.Close()
	}
	defer func() {
		si.mu.Lock()
		si.drop(source, conn)
		si.mu.Unlock()
		time.Sleep(200 * time.Millisecond)
		conn.Close()
	}()
	// A sign-in says little: no line needs more than this.
	conn.ws.SetReadLimit(64 << 10)
	deadline := time.Now().Add(signInWait)
	for asked := 0; asked < 20; asked++ {
		line, err := conn.ReadWithin(time.Until(deadline))
		if err != nil {
			return
		}
		m, ok := decode(line)
		if !ok || !m.isRequest() {
			return
		}
		switch m.Method {
		case "signIn/providers":
			settings, _, err := si.settings(context.Background())
			if err != nil {
				conn.SendNow(replyError(m.ID, fail(storeUnavailable, "The sign-in settings could not be read.")))
				continue
			}
			conn.SendNow(reply(m.ID, si.providers(settings, false, helloNonce)))
		case "signIn/pair":
			p, err := require[wire.SignInPair](m.Params, "SignInPair")
			if err == nil {
				var admitted *wire.Admitted
				admitted, err = si.pair(context.Background(), conn, client, public, helloNonce, p)
				if err == nil {
					conn.SendNow(reply(m.ID, admitted))
					return
				}
			}
			si.s.log("a sign-in with " + signin.Title(p.Provider) + " from " + source + " was refused: " + asRPC(err).Message)
			conn.SendNow(replyError(m.ID, err))
			return
		case "signIn/ask":
			a, err := require[wire.SignInAsk](m.Params, "SignInAsk")
			if err == nil {
				var admitted *wire.Admitted
				admitted, err = si.ask(context.Background(), conn, client, public, a)
				if err == nil {
					conn.SendNow(reply(m.ID, admitted))
					return
				}
			}
			si.s.log("a browser's sign-in by approval from " + source + " was refused: " + asRPC(err).Message)
			conn.SendNow(replyError(m.ID, err))
			return
		case "signIn/orgStart":
			// An org provider's flow (#1002): the browser goes and comes back while this
			// connection waits, then signIn/ticket pairs it.
			o, err := require[wire.SignInOrgStart](m.Params, "SignInOrgStart")
			if err == nil {
				var started wire.SignInOrgStarted
				if started, err = si.orgStart(context.Background(), o, binding{hello: helloNonce, client: client, public: public}); err == nil {
					conn.SendNow(reply(m.ID, started))
					continue
				}
			}
			conn.SendNow(replyError(m.ID, err))
		case "signIn/ticket":
			t, err := require[wire.SignInTicket](m.Params, "SignInTicket")
			if err == nil {
				var paired *wire.SignInTicketResult
				if paired, err = si.ticketPair(context.Background(), client, public, helloNonce, t); err == nil {
					conn.SendNow(reply(m.ID, paired))
					return
				}
			}
			si.s.log("an org sign-in from " + source + " was refused: " + asRPC(err).Message)
			conn.SendNow(replyError(m.ID, err))
			return
		case "signIn/discover":
			d, err := require[wire.SignInDiscover](m.Params, "SignInDiscover")
			if err != nil {
				conn.SendNow(replyError(m.ID, err))
				continue
			}
			conn.SendNow(reply(m.ID, si.discover(context.Background(), d)))
		default:
			conn.SendNow(replyError(m.ID, fail(notPermitted, "Only signIn/providers, signIn/discover, signIn/pair, signIn/ask, signIn/orgStart and signIn/ticket are answered on a sign-in connection.")))
		}
	}
}

// pair is signIn/pair: check the sign-in, find its person, and pair the client as theirs.
func (si *signIns) pair(ctx context.Context, conn *Conn, client string, public, helloNonce []byte, p wire.SignInPair) (*wire.Admitted, error) {
	name := strings.TrimSpace(p.Name)
	kind := string(p.Kind)
	if name == "" || len([]rune(name)) > 80 {
		return nil, fail(invalidParams, "Say the client's name.")
	}
	if kind != records.KindMac && kind != records.KindIPhone && kind != records.KindIPad {
		return nil, fail(invalidParams, "A browser pairs with a code from a signed-in client.")
	}
	settings, _, err := si.settings(ctx)
	if err != nil {
		return nil, fail(storeUnavailable, "The sign-in settings could not be read.")
	}
	c, err := si.check(ctx, settings, p.Provider, p.Token, helloNonce)
	if err != nil {
		return nil, err
	}
	person, err := si.personWithSignIn(ctx, c.provider, c.account)
	if err != nil {
		return nil, err
	}
	// A domain that requires its org provider refuses this one, to join or to pair (D9).
	known := ""
	if person != nil {
		known = person.ID
	}
	if err := si.requiredFor(ctx, c.provider, c.email, known); err != nil {
		return nil, err
	}
	if person == nil {
		id, err := si.joinByDomain(ctx, c, settings)
		if err != nil {
			return nil, err
		}
		if id == "" {
			return nil, fail(notPermitted, "Nobody on this control plane signs in with this %s account. Ask an admin for an invite, pair with its code, and then add this sign-in under Account.",
				signin.Title(c.provider))
		}
		person = si.s.records.Person(id)
	}
	if person.IsRemoved() {
		return nil, fail(notPermitted, "This person was removed from the control plane. Ask an admin for a new invite.")
	}
	if person.IsBot() {
		return nil, fail(notPermitted, "A bot does not sign in.")
	}
	if c.provider == signin.GitHub {
		// A GitHub token carries no nonce, so it could have been passed on: another client of
		// the person approves (R3).
		return si.s.signInApprovals.wait(ctx, conn, signInAsk{client: client, public: public, name: name, kind: kind,
			person: person.ID, login: c.login, provider: c.provider})
	}
	owner := person.ID
	record := records.ClientRecord{ID: client, Name: name, Kind: kind, PublicKey: public, Paired: records.Now(), Owner: &owner,
		Expires: si.s.newExpiry()}
	if err := si.s.methods.Admit(ctx, record); err != nil {
		return nil, err
	}
	si.s.log(name + " paired (" + kind + ") by signing in with " + signin.Title(c.provider) + " as person " + owner)
	si.s.announce("clientPaired", client, "signin")
	return &wire.Admitted{Client: new(wire.UUID(client))}, nil
}

// ask is signIn/ask (#2097): a browser asks to pair as the person with this sign-in's email
// or GitHub login, and waits for that person to type its code on one of their clients. An
// account nobody has waits the same way, so the browser learns nothing of who is here.
func (si *signIns) ask(ctx context.Context, conn *Conn, client string, public []byte, a wire.SignInAsk) (*wire.Admitted, error) {
	name := strings.TrimSpace(a.Name)
	account := strings.TrimSpace(a.Account)
	if name == "" || len([]rune(name)) > 80 {
		return nil, fail(invalidParams, "Say the browser's name.")
	}
	if account == "" || len(account) > 320 {
		return nil, fail(invalidParams, "Type the email or GitHub login of one of your sign-ins.")
	}
	person, signIn := si.personWithAccount(account)
	if signIn != nil {
		// A domain that requires its org provider refuses a built-in sign-in, here too (D9).
		if err := si.requiredFor(ctx, signIn.Provider, signIn.Email, person.ID); err != nil {
			return nil, err
		}
	}
	ask := signInAsk{client: client, public: public, name: name, kind: records.KindBrowser, login: account, provider: browserProvider}
	if person != nil {
		ask.person = person.ID
	}
	return si.s.signInApprovals.wait(ctx, conn, ask)
}

// personWithAccount is the person one of whose outside sign-ins has this email or GitHub
// login, and that sign-in; none for a removed, suspended or bot person.
func (si *signIns) personWithAccount(account string) (*records.Person, *records.SignIn) {
	for _, p := range si.s.records.People() {
		if p.IsRemoved() || p.IsSuspended() || p.IsBot() {
			continue
		}
		for _, s := range p.SignIns {
			if !outsideProvider(s.Provider) {
				continue
			}
			if s.Email != "" && strings.EqualFold(s.Email, account) || s.Provider == signin.GitHub && s.Login != "" && strings.EqualFold(s.Login, account) {
				return &p, &s
			}
		}
	}
	return nil, nil
}

// signInMethod answers signIn/* on a paired client's connection.
func (m *Methods) signInMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	si := m.s.signIns
	user := m.callerPerson(from)
	switch method {
	case "signIn/providers":
		settings, _, err := si.settings(ctx)
		if err != nil {
			return nil, fail(storeUnavailable, "The sign-in settings could not be read: %v", err)
		}
		return si.providers(settings, m.s.isAdmin(user), si.newChallenge(from.Session)), nil
	case "signIn/configure":
		c, err := require[wire.SignInConfigure](params, "SignInConfigure")
		if err != nil {
			return nil, err
		}
		return si.configure(ctx, c, user)
	case "signIn/addToMe":
		a, err := require[wire.SignInAdd](params, "SignInAdd")
		if err != nil {
			return nil, err
		}
		return si.addToMe(ctx, a, from, user)
	case "signIn/removeFromMe":
		r, err := require[wire.SignInRemove](params, "SignInRemove")
		if err != nil {
			return nil, err
		}
		return map[string]any{}, si.removeFromMe(ctx, r, user)
	case "signIn/requests":
		return m.s.signInApprovals.list(ctx, user)
	case "signIn/approve", "signIn/deny":
		d, err := require[wire.SignInDecide](params, "SignInDecide")
		if err != nil {
			return nil, err
		}
		code := ""
		if d.Code != nil {
			code = *d.Code
		}
		return map[string]any{}, m.s.signInApprovals.decide(ctx, d.Request, user, method == "signIn/approve", code)
	case "signIn/pair":
		return nil, fail(notPermitted, "signIn/pair is answered only on a sign-in connection.")
	}
	return m.orgSignInMethod(ctx, method, params, from, user)
}
