package controlplane

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/signin"
	"github.com/alexec/agents/Go/internal/controlplane/signin/signintest"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

const (
	googleApp = "google-app.apps.example"
	appleApp  = "com.alexecollins.agents.remote"
)

// providersFake is a fake Google, Apple and GitHub, shared by the planes of a test.
type providersFake struct {
	google, apple *signintest.Issuer
	github        *signintest.GitHub
}

func newProvidersFake(t *testing.T) *providersFake {
	return &providersFake{google: signintest.NewIssuer(t, "https://accounts.google.com"),
		apple: signintest.NewIssuer(t, "https://appleid.apple.com"), github: signintest.NewGitHub(t)}
}

func (f *providersFake) config() *signin.Config {
	return &signin.Config{GoogleClientIDs: []string{googleApp}, AppleAudiences: []string{appleApp}, AppleEnabled: true,
		GitHubClientID: "Iv1.github-app", GoogleJWKS: f.google.JWKS(), AppleJWKS: f.apple.JWKS(), GitHubAPI: f.github.Server.URL}
}

// signInPlane is a plane that checks sign-ins against the fakes, with its owner's window,
// and every provider turned on.
func signInPlane(t *testing.T, f *providersFake) (*plane, *controllink.ClientMembership, *controllink.Session) {
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) { c.SignIn = f.config() })
	m, owner := p.client("Alex's Mac")
	for _, provider := range signin.Providers {
		call(t, owner, "", "signIn/configure", wire.SignInConfigure{Provider: provider, On: new(true)})
	}
	return p, m, owner
}

// mint is an ID token from a fake issuer for that person, with the nonce given.
func (f *providersFake) mint(provider, sub, nonce string, extra signintest.Claims) string {
	claims := signintest.Claims{"sub": sub, "nonce": nonce}
	issuer := f.google
	claims["aud"] = googleApp
	if provider == signin.Apple {
		issuer, claims["aud"] = f.apple, appleApp
	}
	for k, v := range extra {
		claims[k] = v
	}
	return issuer.Mint(claims)
}

// signInAs pairs a new client by signing in with a token made by make from the nonce.
func (p *plane) signInAs(provider string, make func(nonce string) string, waiting func(wire.SignInWaiting)) (*controllink.ClientMembership, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return controllink.SignIn(ctx, p.url, "", nil, "Sam's iPhone", records.KindIPhone, func(providers wire.SignInProviders, nonce string) (string, string, error) {
		return provider, make(nonce), nil
	}, waiting)
}

// addToMe adds a sign-in to a window's person, with an ID token made for its challenge.
func addToMe(t *testing.T, s *controllink.Session, m *controllink.ClientMembership, provider string, make func(nonce string) string) (json.RawMessage, string) {
	t.Helper()
	var providers wire.SignInProviders
	json.Unmarshal(call(t, s, "", "signIn/providers", map[string]any{}), &providers)
	challenge, err := controllink.FromB64URL(deref(providers.Challenge))
	if err != nil || len(challenge) != 32 {
		t.Fatalf("challenge %v", providers.Challenge)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	got, err := s.Call(ctx, "", "signIn/addToMe", wire.SignInAdd{Provider: provider, Token: make(controllink.SignInNonce(m.ControlKey, challenge))})
	if err != nil {
		return nil, err.Error()
	}
	return got, ""
}

func personOf(t *testing.T, p *plane, m *controllink.ClientMembership) string {
	t.Helper()
	s, err := controllink.DialClient(context.Background(), m)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	var status wire.ControlStatus
	json.Unmarshal(call(t, s, "", "control/status", nil), &status)
	return status.Person.ID
}

// US2 AS1 and AS3 (FR-005, FR-009): the local owner adds a Google and an Apple sign-in
// to themselves, and a new client that signs in with either pairs as them, with no code.
func TestASignInPairsAKnownPersonWithNoCode(t *testing.T) {
	t.Parallel()
	f := newProvidersFake(t)
	p, m, owner := signInPlane(t, f)
	ownerID := personOf(t, p, m)
	for _, provider := range []string{signin.Google, signin.Apple} {
		if _, e := addToMe(t, owner, m, provider, func(n string) string {
			return f.mint(provider, "alex-"+provider, n, signintest.Claims{"email": "alex@example.com"})
		}); e != "" {
			t.Fatalf("%s: %s", provider, e)
		}
		before := len(p.s.Records().Clients())
		member, err := p.signInAs(provider, func(n string) string { return f.mint(provider, "alex-"+provider, n, nil) }, nil)
		if err != nil {
			t.Fatalf("%s: %v", provider, err)
		}
		if got := personOf(t, p, member); got != ownerID {
			t.Fatalf("%s paired as %s, not the owner %s", provider, got, ownerID)
		}
		if len(p.s.Records().Clients()) != before+1 {
			t.Fatal("no client was added")
		}
	}
	// Still one person, with three sign-ins (FR-005).
	var people wire.PeopleList
	json.Unmarshal(call(t, owner, "", "people/list", nil), &people)
	if len(people.People) != 1 || len(people.People[0].SignIns) != 3 {
		t.Fatalf("%+v", people.People)
	}
	// An outside sign-in says its account, to take it off; the local owner's says none.
	for _, in := range people.People[0].SignIns {
		if (in.Provider == "local") != (in.Account == nil) {
			t.Fatalf("%+v", in)
		}
	}
}

// Every refusal (#995): a bad signature, another app, expired, a nonce from an earlier
// connection, a provider turned off, an account nobody has, a removed person. Each pairs
// nothing.
func TestEveryRefusedSignInPairsNothing(t *testing.T) {
	t.Parallel()
	f := newProvidersFake(t)
	p, m, owner := signInPlane(t, f)
	addToMe(t, owner, m, signin.Google, func(n string) string { return f.mint(signin.Google, "alex", n, nil) })
	sam := p.invite(owner, "Sam", wire.UserRoleMember)
	if _, e := addToMe(t, sam.window, sam.member, signin.Apple, func(n string) string { return f.mint(signin.Apple, "sam", n, nil) }); e != "" {
		t.Fatal(e)
	}
	// A token made on an earlier connection, for this control plane.
	var earlier string
	p.signInAs(signin.Google, func(n string) string { earlier = f.mint(signin.Google, "alex", n, nil); return "not a token" }, nil)

	cases := map[string]struct {
		provider string
		token    func(nonce string) string
		want     string
	}{
		"bad signature": {signin.Google, func(n string) string {
			return f.google.Forge(signintest.Claims{"sub": "alex", "aud": googleApp, "nonce": n})
		}, "signature"},
		"wrong aud": {signin.Google, func(n string) string { return f.mint(signin.Google, "alex", n, signintest.Claims{"aud": "other-app"}) }, "another app"},
		"expired": {signin.Google, func(n string) string {
			return f.mint(signin.Google, "alex", n, signintest.Claims{"exp": time.Now().Add(-time.Hour).Unix()})
		}, "expired"},
		"replayed nonce": {signin.Google, func(string) string { return earlier }, "another sign-in"},
		"wrong issuer": {signin.Google, func(n string) string {
			return f.apple.Mint(signintest.Claims{"sub": "alex", "aud": googleApp, "nonce": n})
		}, "signature"},
		"nobody has it":    {signin.Google, func(n string) string { return f.mint(signin.Google, "stranger", n, nil) }, "Ask an admin for an invite"},
		"Apple stranger":   {signin.Apple, func(n string) string { return f.mint(signin.Apple, "stranger", n, nil) }, "Ask an admin for an invite"},
		"GitHub stranger":  {signin.GitHub, func(string) string { return f.github.Token(99, "stranger") }, "Ask an admin for an invite"},
		"GitHub bad token": {signin.GitHub, func(string) string { return "ghu_nope" }, "did not accept"},
	}
	for name, c := range cases {
		_, err := p.signInAs(c.provider, c.token, nil)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v", name, err)
		}
	}
	// Removed (FR-029): Sam's sign-in is refused until a new invite.
	call(t, owner, "", "people/remove", map[string]string{"user": sam.id})
	before := len(p.s.Records().Clients())
	if _, err := p.signInAs(signin.Apple, func(n string) string { return f.mint(signin.Apple, "sam", n, nil) }, nil); err == nil ||
		!strings.Contains(err.Error(), "removed") {
		t.Errorf("removed: %v", err)
	}
	// Turned off: refused.
	call(t, owner, "", "signIn/configure", wire.SignInConfigure{Provider: signin.Google, On: new(false)})
	if _, err := p.signInAs(signin.Google, func(n string) string { return f.mint(signin.Google, "alex", n, nil) }, nil); err == nil ||
		!strings.Contains(err.Error(), "not turned on") {
		t.Errorf("off: %v", err)
	}
	if got := len(p.s.Records().Clients()); got != before {
		t.Fatalf("%d clients were added", got-before)
	}
	// With every provider off, an s: connection is refused at once.
	for _, provider := range signin.Providers {
		call(t, owner, "", "signIn/configure", wire.SignInConfigure{Provider: provider, On: new(false)})
	}
	if _, err := p.signInAs(signin.Apple, func(n string) string { return "x" }, nil); err == nil || !strings.Contains(err.Error(), "unknown") {
		t.Errorf("all off: %v", err)
	}
}

// FR-011, SC-005: a sign-in made for one control plane pairs nothing on another, for
// Google, Apple and GitHub, though both trust the same app.
func TestASignInSentToAnotherControlPlanePairsNothing(t *testing.T) {
	t.Parallel()
	f := newProvidersFake(t)
	a, am, aOwner := signInPlane(t, f)
	b, bm, bOwner := signInPlane(t, f)
	github := f.github.Token(7, "alexec")
	for _, owner := range []struct {
		s *controllink.Session
		m *controllink.ClientMembership
	}{{aOwner, am}, {bOwner, bm}} {
		for _, provider := range []string{signin.Google, signin.Apple} {
			addToMe(t, owner.s, owner.m, provider, func(n string) string { return f.mint(provider, "alex", n, nil) })
		}
		addToMe(t, owner.s, owner.m, signin.GitHub, func(string) string { return github })
	}
	for _, provider := range []string{signin.Google, signin.Apple} {
		// A hostile a keeps the token it was sent, and sends it to b.
		var kept string
		if _, err := a.signInAs(provider, func(n string) string { kept = f.mint(provider, "alex", n, nil); return kept }, nil); err != nil {
			t.Fatal(err)
		}
		if _, err := b.signInAs(provider, func(string) string { return kept }, nil); err == nil || !strings.Contains(err.Error(), "another sign-in") {
			t.Errorf("%s at b: %v", provider, err)
		}
		// Nor does a token for b's nonce, given to a client as if it were a's: the client
		// makes its nonce from a's key, so b's check fails too.
	}
	// GitHub: the token alone pairs nothing at b; it waits for Approve on b, and nobody
	// approves.
	waited := make(chan wire.SignInWaiting, 1)
	go func() {
		w := <-waited
		requests := []wire.SignInRequest{}
		json.Unmarshal(call(t, bOwner, "", "signIn/requests", nil), &requests)
		if len(requests) != 1 || requests[0].Code != w.Code {
			t.Errorf("%+v %+v", requests, w)
		}
		call(t, bOwner, "", "signIn/deny", wire.SignInDecide{Request: requests[0].Request})
	}()
	before := len(b.s.Records().Clients())
	if _, err := b.signInAs(signin.GitHub, func(string) string { return github }, func(w wire.SignInWaiting) { waited <- w }); err == nil ||
		!strings.Contains(err.Error(), "denied") {
		t.Fatalf("GitHub at b: %v", err)
	}
	if len(b.s.Records().Clients()) != before {
		t.Fatal("a GitHub token alone paired a client")
	}
}

// FR-010, R3: a GitHub person joins by an invite, adds GitHub, and each later client
// waits for Approve on one of their clients, which shows the same code. Nobody else
// decides it. The control plane asks GitHub once and keeps no token.
func TestAGitHubSignInWaitsForThePersonsApprove(t *testing.T) {
	t.Parallel()
	f := newProvidersFake(t)
	p, _, owner := signInPlane(t, f)
	sam := p.invite(owner, "Sam", wire.UserRoleMember)
	kim := p.invite(owner, "Kim", wire.UserRoleMember)
	token := f.github.Token(4242, "sam")
	got, e := addToMe(t, sam.window, sam.member, signin.GitHub, func(string) string { return token })
	var in wire.SignIn
	json.Unmarshal(got, &in)
	if e != "" || deref(in.Account) != "4242" || deref(in.Login) != "sam" {
		t.Fatalf("%s %+v", e, in)
	}
	// people/list never says an invite code's id, which is part of its secret.
	var list wire.PeopleList
	json.Unmarshal(call(t, sam.window, "", "people/list", nil), &list)
	for _, in := range list.People[0].SignIns {
		if in.Provider == "code" && in.Account != nil {
			t.Fatalf("a code's account is listed: %+v", in)
		}
	}
	// Kim cannot add Sam's GitHub to herself.
	if _, e := addToMe(t, kim.window, kim.member, signin.GitHub, func(string) string { return token }); !strings.Contains(e, "another person's") {
		t.Fatal(e)
	}

	second := f.github.Token(4242, "sam")
	var mu sync.Mutex
	var shown wire.SignInWaiting
	done := make(chan error, 1)
	var member *controllink.ClientMembership
	go func() {
		m, err := p.signInAs(signin.GitHub, func(string) string { return second }, func(w wire.SignInWaiting) {
			mu.Lock()
			shown = w
			mu.Unlock()
		})
		member = m
		done <- err
	}()
	note := waitNote(t, sam.window, "control/signInRequested")
	var asked wire.SignInRequest
	json.Unmarshal(note.Params, &asked)
	// The new client reads its code on its own connection, maybe after the card came.
	code := ""
	p.waitFor(func() bool {
		mu.Lock()
		defer mu.Unlock()
		code = shown.Code
		return code != ""
	}, "the code on the new client")
	if asked.Code == "" || asked.Code != code || deref(asked.Login) != "sam" || asked.Provider != "github" || asked.Kind != "iPhone" {
		t.Fatalf("%+v, the client shows %q", asked, code)
	}
	for _, s := range []*controllink.Session{kim.window, owner} {
		if e := callError(t, s, "", "signIn/approve", wire.SignInDecide{Request: asked.Request}); !strings.Contains(e, "no such sign-in") {
			t.Fatal(e)
		}
		var requests []wire.SignInRequest
		json.Unmarshal(call(t, s, "", "signIn/requests", nil), &requests)
		if len(requests) != 0 {
			t.Fatalf("someone else sees %+v", requests)
		}
	}
	call(t, sam.window, "", "signIn/approve", wire.SignInDecide{Request: asked.Request})
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if got := personOf(t, p, member); got != sam.id {
		t.Fatalf("paired as %s", got)
	}
	if e := callError(t, sam.window, "", "signIn/approve", wire.SignInDecide{Request: asked.Request}); !strings.Contains(e, "ended") {
		t.Fatal(e)
	}
	// Asked once each (GET /user), and no token anywhere in the store or the log.
	if f.github.Seen(second) != 1 {
		t.Fatalf("GitHub was asked %d times", f.github.Seen(second))
	}
	noSecretKept(t, p, token, second)
}

// #2097 (FR-014a, FR-014b): a browser asks by a sign-in's email; the person's card has no
// code, and Approve needs the code the browser shows. An account nobody has waits the same.
func TestABrowserPairsByApprovalWithItsCode(t *testing.T) {
	t.Parallel()
	f := newProvidersFake(t)
	p, _, owner := signInPlane(t, f)
	sam := p.invite(owner, "Sam", wire.UserRoleMember)
	if _, e := addToMe(t, sam.window, sam.member, signin.Google, func(n string) string {
		return f.mint(signin.Google, "sam-google", n, signintest.Claims{"email": "sam@example.com"})
	}); e != "" {
		t.Fatal(e)
	}
	ask := func(account string) (chan error, func() string, chan *controllink.ClientMembership, context.CancelFunc) {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		var mu sync.Mutex
		shown := ""
		done, member := make(chan error, 1), make(chan *controllink.ClientMembership, 1)
		go func() {
			m, err := controllink.SignInByApproval(ctx, p.url, "", nil, "Chrome on Mac", account, func(w wire.SignInWaiting) {
				mu.Lock()
				shown = w.Code
				mu.Unlock()
			})
			member <- m
			done <- err
		}()
		return done, func() string { mu.Lock(); defer mu.Unlock(); return shown }, member, cancel
	}

	// Nobody has this account: a code is shown, and nobody is asked.
	_, shownNobody, _, stop := ask("nobody@example.com")
	p.waitFor(func() bool { return shownNobody() != "" }, "the code for an account nobody has")
	var requests []wire.SignInRequest
	for _, s := range []*controllink.Session{sam.window, owner} {
		json.Unmarshal(call(t, s, "", "signIn/requests", nil), &requests)
		if len(requests) != 0 {
			t.Fatalf("an account nobody has asked %+v", requests)
		}
	}
	stop()

	done, shown, member, cancel := ask("SAM@example.com")
	defer cancel()
	note := waitNote(t, sam.window, "control/signInRequested")
	var asked wire.SignInRequest
	json.Unmarshal(note.Params, &asked)
	p.waitFor(func() bool { return shown() != "" }, "the code in the browser")
	if asked.Code != "" || asked.Provider != "browser" || asked.Kind != "browser" || deref(asked.Login) != "SAM@example.com" {
		t.Fatalf("the card is %+v", asked)
	}
	for _, typed := range []*string{nil, new("WRONG1")} {
		if e := callError(t, sam.window, "", "signIn/approve", wire.SignInDecide{Request: asked.Request, Code: typed}); !strings.Contains(e, "not the code") {
			t.Fatalf("approved with %v: %s", typed, e)
		}
	}
	typed := strings.ToLower(shown()[:3]) + " " + shown()[3:]
	call(t, sam.window, "", "signIn/approve", wire.SignInDecide{Request: asked.Request, Code: &typed})
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	// A browser connects as the page does, not as a window: its record says whose it is.
	got := p.s.Records().Client((<-member).Client)
	if got == nil || got.Kind != records.KindBrowser || got.Owner == nil || *got.Owner != sam.id {
		t.Fatalf("paired as %+v", got)
	}
}

// FR-006: with organisations allowed, a GitHub sign-in outside them is refused, to add or
// to pair; inside one it works.
func TestAllowedGitHubOrganisations(t *testing.T) {
	t.Parallel()
	f := newProvidersFake(t)
	p, m, owner := signInPlane(t, f)
	var shown wire.SignInProviders
	json.Unmarshal(call(t, owner, "", "signIn/configure", wire.SignInConfigure{Provider: signin.GitHub, Organisations: []string{"acme", " acme "}}), &shown)
	if len(shown.Organisations) != 1 || shown.Organisations[0] != "acme" {
		t.Fatalf("%+v", shown)
	}
	if _, e := addToMe(t, owner, m, signin.GitHub, func(string) string { return f.github.Token(1, "alexec", "other") }); !strings.Contains(e, "not in an organisation") {
		t.Fatal(e)
	}
	if _, e := addToMe(t, owner, m, signin.GitHub, func(string) string { return f.github.Token(1, "alexec", "ACME") }); e != "" {
		t.Fatal(e)
	}
	if e := callError(t, owner, "", "signIn/configure", wire.SignInConfigure{Provider: signin.GitHub, Organisations: []string{"no spaces allowed"}}); !strings.Contains(e, "not a GitHub organisation") {
		t.Fatal(e)
	}
	if _, err := p.signInAs(signin.GitHub, func(string) string { return f.github.Token(1, "alexec") }, nil); err == nil || !strings.Contains(err.Error(), "not in an organisation") {
		t.Fatal(err)
	}
}

// US2 AS8 (FR-006): a Google Workspace account on an allowed domain joins as a member with
// no invite. Another domain, a personal account and an email not verified do not.
func TestAnAllowedGoogleDomainJoinsWithNoInvite(t *testing.T) {
	t.Parallel()
	f := newProvidersFake(t)
	p, _, owner := signInPlane(t, f)
	call(t, owner, "", "signIn/configure", wire.SignInConfigure{Provider: signin.Google, Domains: []string{"Example.com"}})
	refused := map[string]signintest.Claims{
		"other domain":   {"hd": "evil.example", "email": "x@evil.example", "email_verified": true},
		"personal":       {"email": "x@gmail.com", "email_verified": true},
		"not verified":   {"hd": "example.com", "email": "x@example.com", "email_verified": false},
	}
	for name, claims := range refused {
		if _, err := p.signInAs(signin.Google, func(n string) string { return f.mint(signin.Google, "x-"+name, n, claims) }, nil); err == nil ||
			!strings.Contains(err.Error(), "invite") {
			t.Errorf("%s: %v", name, err)
		}
	}
	member, err := p.signInAs(signin.Google, func(n string) string {
		return f.mint(signin.Google, "kim", n, signintest.Claims{"hd": "example.com", "email": "kim@example.com", "email_verified": true, "name": "Kim"})
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	s, err := controllink.DialClient(context.Background(), member)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	var status wire.ControlStatus
	json.Unmarshal(call(t, s, "", "control/status", nil), &status)
	if status.Person.Name != "Kim" || status.Person.Role != wire.UserRoleMember {
		t.Fatalf("%+v", status.Person)
	}
	// The same account again is the same person.
	again, err := p.signInAs(signin.Google, func(n string) string {
		return f.mint(signin.Google, "kim", n, signintest.Claims{"hd": "example.com", "email": "kim@example.com", "email_verified": true})
	}, nil)
	if err != nil || personOf(t, p, again) != status.Person.ID {
		t.Fatal(err)
	}
}

// FR-015: a provider that cannot be reached says sign-in is not available, and why;
// paired clients carry on.
func TestAProviderThatCannotBeReachedSaysSo(t *testing.T) {
	t.Parallel()
	f := newProvidersFake(t)
	p, _, owner := signInPlane(t, f)
	f.google.Down.Store(true)
	f.github.Down.Store(true)
	if _, err := p.signInAs(signin.Google, func(n string) string { return f.mint(signin.Google, "alex", n, nil) }, nil); err == nil ||
		!strings.Contains(err.Error(), "not available") {
		t.Fatal(err)
	}
	if _, err := p.signInAs(signin.GitHub, func(string) string { return "ghu_x" }, nil); err == nil || !strings.Contains(err.Error(), "not available") {
		t.Fatal(err)
	}
	call(t, owner, "", "control/status", nil)
}

// Only admins configure; a member sees the providers but not the domains; a provider this
// build has no id for cannot be turned on; a challenge is used once; a sign-in can be
// taken off again.
func TestSignInSettingsAndChallenges(t *testing.T) {
	t.Parallel()
	f := newProvidersFake(t)
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) {
		cfg := f.config()
		cfg.GitHubClientID = ""
		c.SignIn = cfg
	})
	m, owner := p.client("Alex's Mac")
	if e := callError(t, owner, "", "signIn/configure", wire.SignInConfigure{Provider: signin.GitHub, On: new(true)}); !strings.Contains(e, "no GitHub App") {
		t.Fatal(e)
	}
	var shown wire.SignInProviders
	json.Unmarshal(call(t, owner, "", "signIn/configure", wire.SignInConfigure{Provider: signin.Google, On: new(true), Domains: []string{"example.com"}}), &shown)
	if len(shown.Providers) != 3 || shown.Domains[0] != "example.com" {
		t.Fatalf("%+v", shown)
	}
	for _, row := range shown.Providers {
		switch row.Provider {
		case signin.Google:
			if !row.On || deref(row.ClientID) != googleApp {
				t.Fatalf("%+v", row)
			}
		case signin.GitHub:
			if row.On || row.Available || row.Why == nil {
				t.Fatalf("%+v", row)
			}
		}
	}
	sam := p.invite(owner, "Sam", wire.UserRoleMember)
	if e := callError(t, sam.window, "", "signIn/configure", wire.SignInConfigure{Provider: signin.Google, On: new(false)}); !strings.Contains(e, "Only an admin") {
		t.Fatal(e)
	}
	var seen wire.SignInProviders
	json.Unmarshal(call(t, sam.window, "", "signIn/providers", nil), &seen)
	if seen.Domains != nil || seen.Challenge == nil {
		t.Fatalf("a member sees %+v", seen)
	}
	// A challenge is used once.
	var providers wire.SignInProviders
	json.Unmarshal(call(t, owner, "", "signIn/providers", nil), &providers)
	challenge, _ := controllink.FromB64URL(deref(providers.Challenge))
	token := f.mint(signin.Google, "alex", controllink.SignInNonce(m.ControlKey, challenge), nil)
	call(t, owner, "", "signIn/addToMe", wire.SignInAdd{Provider: signin.Google, Token: token})
	if e := callError(t, owner, "", "signIn/addToMe", wire.SignInAdd{Provider: signin.Google, Token: token}); !strings.Contains(e, "challenge") {
		t.Fatal(e)
	}
	call(t, owner, "", "signIn/removeFromMe", wire.SignInRemove{Provider: signin.Google, Account: "alex"})
	if e := callError(t, owner, "", "signIn/removeFromMe", wire.SignInRemove{Provider: "local", Account: "x"}); !strings.Contains(e, "Only a Google") {
		t.Fatal(e)
	}
	if _, err := p.signInAs(signin.Google, func(n string) string { return f.mint(signin.Google, "alex", n, nil) }, nil); err == nil {
		t.Fatal("a sign-in taken off still pairs")
	}
	// signIn/pair is not answered on a paired client's connection.
	if e := callError(t, owner, "", "signIn/pair", wire.SignInPair{Provider: "google", Token: "x", Name: "x", Kind: "mac"}); !strings.Contains(e, "only on a sign-in connection") {
		t.Fatal(e)
	}
}

// noSecretKept reads every object in the store and every log line for the tokens.
func noSecretKept(t *testing.T, p *plane, secrets ...string) {
	t.Helper()
	ctx := context.Background()
	listed, err := p.store.List(ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range listed {
		object, _ := p.store.Get(ctx, entry.Key)
		for _, secret := range secrets {
			if object != nil && strings.Contains(string(object.Data), secret) {
				t.Fatalf("%s holds a token", entry.Key)
			}
		}
	}
	for {
		select {
		case line := <-p.lines:
			for _, secret := range secrets {
				if strings.Contains(line, secret) {
					t.Fatalf("the log holds a token: %s", line)
				}
			}
		default:
			return
		}
	}
}
