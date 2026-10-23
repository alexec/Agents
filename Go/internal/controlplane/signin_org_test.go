package controlplane

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
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

// Org providers and domains (#1002, slice 1), against a fake OIDC provider over TLS on
// loopback and a fake DNS (research R7). No real Okta or Entra: that is Alex's test.

// fakeDNS answers TXT lookups from a map.
type fakeDNS struct {
	mu  sync.Mutex
	txt map[string][]string
}

func (d *fakeDNS) LookupTXT(_ context.Context, name string) ([]string, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if v, ok := d.txt[name]; ok {
		return v, nil
	}
	return nil, errors.New("no such host")
}

func (d *fakeDNS) set(name string, values ...string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.txt == nil {
		d.txt = map[string][]string{}
	}
	if len(values) == 0 {
		delete(d.txt, name)
		return
	}
	d.txt[name] = values
}

// orgPlane is a plane with a keeper, the fake provider's TLS trusted, the built-in fakes
// turned on, and the fake DNS. Its owner's window is returned.
func orgPlane(t *testing.T, prov *signintest.Provider, f *providersFake) (*plane, *controllink.ClientMembership, *controllink.Session, *fakeDNS) {
	key := newKeeperKey()
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) {
		withKeeper(key)(c)
		cfg := &signin.Config{}
		if f != nil {
			cfg = f.config()
		}
		cfg.HTTP = prov.HTTP()
		c.SignIn = cfg
	})
	dns := &fakeDNS{}
	p.s.signIns.org.mu.Lock()
	p.s.signIns.org.dns = dns
	p.s.signIns.org.mu.Unlock()
	m, owner := p.client("Alex's Mac")
	if f != nil {
		for _, provider := range signin.Providers {
			call(t, owner, "", "signIn/configure", wire.SignInConfigure{Provider: provider, On: new(true)})
		}
	}
	return p, m, owner, dns
}

// orgProvider is the fake as an admin types it in.
func orgProvider(prov *signintest.Provider, join wire.OrgProviderJoin) wire.OrgProvider {
	return wire.OrgProvider{Name: "Acme Okta", Preset: wire.OrgProviderPresetOkta, Issuer: prov.Issuer, ClientID: prov.ClientID, Join: &join}
}

func addOrg(t *testing.T, owner *controllink.Session, prov *signintest.Provider, join wire.OrgProviderJoin) wire.OrgProviderKept {
	t.Helper()
	var kept wire.OrgProviderKept
	json.Unmarshal(call(t, owner, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: orgProvider(prov, join), Secret: &prov.ClientSecret}), &kept)
	if kept.Provider.ID != "acme-okta" || deref(kept.Provider.Version) != 1 || kept.Rev == "" {
		t.Fatalf("%+v", kept)
	}
	return kept
}

// browser follows a flow's address as a browser does, and stops where it is sent back to
// the client: agents://oidc, or the page with a fragment. It says what the fragment
// holds, and the callback it went through.
type browser struct {
	prov     *signintest.Provider
	callback string
}

func (b *browser) open(t *testing.T, start string) url.Values {
	t.Helper()
	client := &http.Client{Transport: b.prov.HTTP().Transport, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if req.URL.Path == "/v1/oidc/callback" {
			b.callback = req.URL.String()
		}
		if req.URL.Scheme == "agents" || req.URL.Fragment != "" {
			return http.ErrUseLastResponse
		}
		return nil
	}}
	resp, err := client.Get(start)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.Header.Get("Cache-Control") != "no-store" || resp.Header.Get("Referrer-Policy") != "no-referrer" {
		t.Fatalf("headers %v", resp.Header)
	}
	loc, err := url.Parse(resp.Header.Get("Location"))
	if err != nil || resp.StatusCode != http.StatusFound {
		t.Fatalf("%d %s", resp.StatusCode, resp.Header.Get("Location"))
	}
	values, _ := url.ParseQuery(loc.Fragment)
	if loc.Scheme != "agents" {
		web := url.Values{}
		for k, v := range values {
			web[strings.TrimPrefix(k, "oidc-")] = v
		}
		values = web
	}
	return values
}

// ticket is browse for controllink.SignInOrg: the ticket, or the error the page shows.
func (b *browser) ticket(t *testing.T) func(string) (string, error) {
	return func(start string) (string, error) {
		v := b.open(t, start)
		if v.Get("ticket") == "" {
			return "", errors.New(v.Get("error") + ": " + v.Get("message"))
		}
		return v.Get("ticket"), nil
	}
}

func (p *plane) signInOrg(t *testing.T, b *browser) (*controllink.ClientMembership, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return controllink.SignInOrg(ctx, p.url, "", nil, "Sam's iPhone", records.KindIPhone, "acme-okta", b.ticket(t))
}

// orgStartOn starts the flow on an open s: connection.
func orgStartOn(t *testing.T, s *controllink.SignInSession, returnTo wire.SignInOrgReturn) string {
	t.Helper()
	raw, err := s.Call(context.Background(), "signIn/orgStart", wire.SignInOrgStart{Provider: "acme-okta", Purpose: wire.SignInOrgPurposePair, ReturnTo: returnTo})
	if err != nil {
		t.Fatal(err)
	}
	var started wire.SignInOrgStarted
	json.Unmarshal(raw, &started)
	return started.URL
}

func ticketOn(s *controllink.SignInSession, ticket string, kind wire.ClientKind) error {
	_, err := s.Call(context.Background(), "signIn/ticket", wire.SignInTicket{Ticket: ticket, Name: new("Sam's Mac"), Kind: &kind})
	return err
}

func openSignIn(t *testing.T, p *plane) *controllink.SignInSession {
	t.Helper()
	s, err := controllink.OpenSignIn(context.Background(), p.url, "", nil, records.KindMac)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	return s
}

// T001, SC-001, US1: with no org provider nothing changes. signIn/providers lists none,
// /v1/oidc/* is not there, and an s: connection with no provider on is refused as before.
func TestNoOrgProviderChangesNothing(t *testing.T) {
	t.Parallel()
	prov := signintest.NewProvider(t, "RS256", "")
	p, _, owner, _ := orgPlane(t, prov, nil)
	var providers wire.SignInProviders
	json.Unmarshal(call(t, owner, "", "signIn/providers", nil), &providers)
	if providers.OrgProviders != nil || providers.Discover != nil {
		t.Fatalf("%+v", providers)
	}
	for _, path := range []string{"/v1/oidc/start?s=abc", "/v1/oidc/callback?state=abc&code=x"} {
		resp, err := http.Get(p.url + path)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusNotFound {
			t.Fatalf("%s: %d", path, resp.StatusCode)
		}
	}
	if _, err := controllink.OpenSignIn(context.Background(), p.url, "", nil, records.KindMac); err == nil || !strings.Contains(err.Error(), "unknown") {
		t.Fatalf("an s: connection with nothing on: %v", err)
	}
	var list wire.OrgProviderList
	json.Unmarshal(call(t, owner, "", "signIn/orgProviders/list", nil), &list)
	if len(list.Providers) != 0 {
		t.Fatalf("%+v", list)
	}
}

// T003, FR-001 to FR-004, SC-005: an admin's provider, its bounds, its rev and version,
// what a member may do, and the secret nowhere but sealed.
func TestOrgProviderSettings(t *testing.T) {
	t.Parallel()
	prov := signintest.NewProvider(t, "RS256", "/oauth2/default")
	p, _, owner, _ := orgPlane(t, prov, nil)
	sam := p.invite(owner, "Sam", wire.UserRoleMember)
	if e := callError(t, sam.window, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: orgProvider(prov, "invite"), Secret: &prov.ClientSecret}); !strings.Contains(e, "Only an admin") {
		t.Fatal(e)
	}
	bad := map[string]func(*wire.OrgProvider){
		"no name":      func(o *wire.OrgProvider) { o.Name = " " },
		"long name":    func(o *wire.OrgProvider) { o.Name = strings.Repeat("x", 41) },
		"bad id":       func(o *wire.OrgProvider) { o.ID = "Not An ID" },
		"built-in id":  func(o *wire.OrgProvider) { o.ID = "google" },
		"http issuer":  func(o *wire.OrgProvider) { o.Issuer = strings.Replace(o.Issuer, "https", "http", 1) },
		"no preset":    func(o *wire.OrgProvider) { o.Preset = "" },
		"no client":    func(o *wire.OrgProvider) { o.ClientID = "" },
		"bad join":     func(o *wire.OrgProvider) { o.Join = new(wire.OrgProviderJoin("everyone")) },
		"bad claim":    func(o *wire.OrgProvider) { o.AccountClaim = new("no spaces") },
		"entra issuer": func(o *wire.OrgProvider) { o.Preset = wire.OrgProviderPresetEntra; o.Issuer = "https://login.example" },
	}
	for name, change := range bad {
		o := orgProvider(prov, "invite")
		change(&o)
		if e := callError(t, owner, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: o, Secret: &prov.ClientSecret}); !strings.Contains(e, "-32602") {
			t.Errorf("%s: %s", name, e)
		}
	}
	if e := callError(t, owner, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: orgProvider(prov, "invite")}); !strings.Contains(e, "client secret") {
		t.Fatal(e)
	}
	// FR-004: an issuer without PKCE S256 is refused, and says so.
	prov.ChangeDiscovery(func(d map[string]any) { delete(d, "code_challenge_methods_supported") })
	if e := callError(t, owner, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: orgProvider(prov, "invite"), Secret: &prov.ClientSecret}); !strings.Contains(e, "-32082") || !strings.Contains(e, "PKCE with S256") {
		t.Fatal(e)
	}
	prov.ChangeDiscovery(nil)

	kept := addOrg(t, owner, prov, wire.OrgProviderJoinInvite)
	if deref(kept.Provider.AccountClaim) != "sub" || deref(kept.Provider.Join) != "invite" || !deref(kept.Provider.On) ||
		kept.Provider.Secret == nil || kept.Provider.Secret.Fingerprint != fingerprint(prov.ClientSecret) ||
		!strings.HasSuffix(deref(kept.Provider.RedirectURI), "/v1/oidc/callback") || kept.Provider.Scopes[0] != "openid" {
		t.Fatalf("%+v", kept.Provider)
	}
	// A second add, and a stale rev, are changedElsewhere; the right rev is version 2.
	change := kept.Provider
	change.Name = "Acme"
	if e := callError(t, owner, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: change}); !strings.Contains(e, "-32093") {
		t.Fatal(e)
	}
	if e := callError(t, owner, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: change, Rev: new("stale")}); !strings.Contains(e, "-32093") {
		t.Fatal(e)
	}
	var again wire.OrgProviderKept
	json.Unmarshal(call(t, owner, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: change, Rev: &kept.Rev}), &again)
	if deref(again.Provider.Version) != 2 || again.Provider.Name != "Acme" || again.Provider.Secret.Fingerprint != kept.Provider.Secret.Fingerprint {
		t.Fatalf("%+v", again.Provider)
	}
	// Check reads the document and the JWKS again.
	var check wire.OrgProviderCheck
	json.Unmarshal(call(t, owner, "", "signIn/orgProviders/check", wire.OrgProviderRequest{ID: "acme-okta"}), &check)
	if !check.Ok || check.JwksKeys != 2 || len(check.Missing) != 0 {
		t.Fatalf("%+v", check)
	}
	// Every client sees the id, the name and the order, and nothing more (FR-003).
	var shown wire.SignInProviders
	raw := call(t, sam.window, "", "signIn/providers", nil)
	json.Unmarshal(raw, &shown)
	if len(shown.OrgProviders) != 1 || shown.OrgProviders[0] != (wire.SignInOrgProvider{ID: "acme-okta", Name: "Acme"}) ||
		strings.Contains(string(raw), prov.ClientID) {
		t.Fatalf("%s", raw)
	}
	// Five at most (D7); a removed one keeps its id.
	for i := range 4 {
		o := orgProvider(prov, "invite")
		o.Name = "Other " + string(rune('A'+i))
		call(t, owner, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: o, Secret: &prov.ClientSecret})
	}
	sixth := orgProvider(prov, "invite")
	sixth.Name = "Sixth"
	if e := callError(t, owner, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: sixth, Secret: &prov.ClientSecret}); !strings.Contains(e, "5 org providers at most") {
		t.Fatal(e)
	}
	call(t, owner, "", "signIn/orgProviders/remove", wire.OrgProviderRequest{ID: "other-d"})
	reuse := orgProvider(prov, "invite")
	reuse.Name, reuse.ID = "Other D", "other-d"
	if e := callError(t, owner, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: reuse, Secret: &prov.ClientSecret}); !strings.Contains(e, "was a provider that was removed") {
		t.Fatal(e)
	}
	// No answer and no store file holds the secret, as it is, in base64 or in hex (SC-005).
	for _, method := range []string{"signIn/orgProviders/list"} {
		if raw := call(t, owner, "", method, nil); strings.Contains(string(raw), prov.ClientSecret) {
			t.Fatalf("%s returns the secret", method)
		}
	}
	secret := []byte(prov.ClientSecret)
	noSecretKept(t, p, prov.ClientSecret, base64.StdEncoding.EncodeToString(secret), base64.RawURLEncoding.EncodeToString(secret), hex.EncodeToString(secret))
	// The audit says the provider was added, with the fingerprint, never the secret.
	p.waitFor(func() bool {
		var list wire.AuditList
		json.Unmarshal(call(t, owner, "", "audit/list", nil), &list)
		for _, e := range list.Entries {
			if e.Method == "signIn/orgProviders/set" && strings.Contains(deref(e.Target), fingerprint(prov.ClientSecret)) {
				return true
			}
		}
		return false
	}, "the audit entry")
}

// FR-002, D18: an org provider needs an https address; http only on loopback.
func TestOrgProvidersNeedAnHTTPSAddress(t *testing.T) {
	t.Parallel()
	for address, want := range map[string]string{
		"https://control.example.com":    "https://control.example.com",
		"wss://control.example.com:8443": "https://control.example.com:8443",
		"http://127.0.0.1:8790":          "http://127.0.0.1:8790",
		"http://control.example.com":     "",
		"":                               "",
	} {
		si := &signIns{s: &Service{cfg: Config{URL: address}}}
		if got, _ := si.httpsBase(); got != want {
			t.Errorf("%q: %q", address, got)
		}
	}
	// And a keeper: with none, nothing is saved.
	prov := signintest.NewProvider(t, "RS256", "")
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) { c.SignIn = &signin.Config{HTTP: prov.HTTP()} })
	_, owner := p.client("Alex's Mac")
	if e := callError(t, owner, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: orgProvider(prov, "invite"), Secret: &prov.ClientSecret}); !strings.Contains(e, "-32082") || !strings.Contains(e, "keeper") {
		t.Fatal(e)
	}
}

// T004, FR-005, FR-006, SC-004: the flow pairs the connection that started it, with RS256
// and ES256, and nothing else pairs: an unknown or used state, a bad token, a ticket on
// another connection or late, and an ID token sent to the control plane.
func TestAnOrgSignInPairsByTicket(t *testing.T) {
	t.Parallel()
	for _, alg := range []string{"RS256", "ES256"} {
		t.Run(alg, func(t *testing.T) {
			prov := signintest.NewProvider(t, alg, "/oauth2/default")
			p, _, owner, _ := orgPlane(t, prov, nil)
			addOrg(t, owner, prov, wire.OrgProviderJoinAnyone)
			b := &browser{prov: prov}
			member, err := p.signInOrg(t, b)
			if err != nil {
				t.Fatal(err)
			}
			sam := personOf(t, p, member)
			got := p.s.records.Person(sam)
			if got == nil || got.Name != "Sam" || got.Role != records.RoleMember || !got.HasSignIn("acme-okta", "00u-sam") {
				t.Fatalf("%+v", got)
			}
			// The authorize request had what D2 asks for.
			q := prov.Authorized()[0]
			if q.Get("code_challenge_method") != "S256" || q.Get("nonce") == "" || q.Get("state") == "" || !strings.Contains(q.Get("scope"), "openid") ||
				q.Get("redirect_uri") != p.url+"/v1/oidc/callback" {
				t.Fatalf("%v", q)
			}
			// The same account again is the same person.
			again, err := p.signInOrg(t, b)
			if err != nil || personOf(t, p, again) != sam {
				t.Fatal(err)
			}
			// The callback again (a used state) and an unknown state pair nothing.
			for _, callback := range []string{b.callback, p.url + "/v1/oidc/callback?state=" + strings.Repeat("A", 22) + "&code=x"} {
				resp, err := http.Get(callback)
				if err != nil {
					t.Fatal(err)
				}
				resp.Body.Close()
				if resp.StatusCode != http.StatusBadRequest {
					t.Fatalf("%s: %d", callback, resp.StatusCode)
				}
			}
			noSecretKept(t, p, append(prov.Issued(), prov.ClientSecret)...)
		})
	}
}

func TestEveryRefusedOrgSignInPairsNothing(t *testing.T) {
	t.Parallel()
	prov := signintest.NewProvider(t, "RS256", "")
	p, _, owner, _ := orgPlane(t, prov, nil)
	addOrg(t, owner, prov, wire.OrgProviderJoinAnyone)
	b := &browser{prov: prov}
	before := len(p.s.Records().Clients())
	cases := map[string]struct {
		set  func()
		want string
	}{
		"bad signature": {func() { prov.Forge.Store(true) }, "signature"},
		"wrong iss":     {func() { prov.Mutate(func(c signintest.Claims) { c["iss"] = "https://evil.example" }) }, "not from"},
		"wrong aud":     {func() { prov.Mutate(func(c signintest.Claims) { c["aud"] = "other-client" }) }, "another app"},
		"expired":       {func() { prov.Mutate(func(c signintest.Claims) { c["exp"] = time.Now().Add(-time.Hour).Unix() }) }, "expired"},
		"wrong nonce":   {func() { prov.Mutate(func(c signintest.Claims) { c["nonce"] = "another" }) }, "another sign-in"},
		"no account":    {func() { prov.Mutate(func(c signintest.Claims) { delete(c, "sub") }) }, "names nobody"},
		"denied":        {func() { prov.Deny("access_denied") }, "access_denied"},
	}
	for name, c := range cases {
		c.set()
		if _, err := p.signInOrg(t, b); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v", name, err)
		}
		prov.Forge.Store(false)
		prov.Mutate(nil)
		prov.Deny("")
	}
	if got := len(p.s.Records().Clients()); got != before {
		t.Fatalf("%d clients were paired", got-before)
	}

	// A ticket shown on another connection is refused and not spent: the one that started
	// the flow still pairs with it.
	first, second := openSignIn(t, p), openSignIn(t, p)
	v := b.open(t, orgStartOn(t, first, wire.SignInOrgReturnApp))
	if err := ticketOn(second, v.Get("ticket"), wire.ClientKindMac); err == nil || !strings.Contains(err.Error(), "another connection") {
		t.Fatal(err)
	}
	if err := ticketOn(first, v.Get("ticket"), wire.ClientKindMac); err != nil {
		t.Fatal(err)
	}
	// Used once.
	third := openSignIn(t, p)
	if err := ticketOn(third, v.Get("ticket"), wire.ClientKindMac); err == nil {
		t.Fatal("a used ticket paired again")
	}
	// A browser kind only by the page's flow. A refused ticket closes its connection, as a
	// refused signIn/pair does.
	fourth := openSignIn(t, p)
	v = b.open(t, orgStartOn(t, fourth, wire.SignInOrgReturnApp))
	if err := ticketOn(fourth, v.Get("ticket"), wire.ClientKindBrowser); err == nil || !strings.Contains(err.Error(), "pairs elsewhere") {
		t.Fatal(err)
	}
	// The page's flow comes back to the page, with the ticket in the fragment.
	page := openSignIn(t, p)
	v = b.open(t, orgStartOn(t, page, wire.SignInOrgReturnWeb))
	if err := ticketOn(page, v.Get("ticket"), wire.ClientKindBrowser); err != nil {
		t.Fatal(err)
	}
	// A ticket after 2 minutes.
	late := openSignIn(t, p)
	v = b.open(t, orgStartOn(t, late, wire.SignInOrgReturnApp))
	p.s.signIns.org.skew.Store(int64(3 * time.Minute))
	if err := ticketOn(late, v.Get("ticket"), wire.ClientKindMac); err == nil || !strings.Contains(err.Error(), "2 minutes") {
		t.Fatal(err)
	}
	// A state after 10 minutes.
	p.s.signIns.org.skew.Store(0)
	slow := openSignIn(t, p)
	start := orgStartOn(t, slow, wire.SignInOrgReturnApp)
	p.s.signIns.org.skew.Store(int64(11 * time.Minute))
	resp, err := http.Get(start)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("a state after 10 minutes: %d", resp.StatusCode)
	}
	p.s.signIns.org.skew.Store(0)
	// An ID token for this control plane's client, sent as a built-in sign-in, pairs
	// nothing: an org provider takes no token from a client (D2).
	token := prov.MintID(signintest.Claims{"sub": "00u-sam"})
	if _, err := p.signInAs("acme-okta", func(string) string { return token }, nil); err == nil {
		t.Fatal("an ID token paired a client")
	}
}

// A callback may come to another copy than the one that started the flow: the state and
// the ticket are store records.
func TestAnOrgSignInCrossesCopies(t *testing.T) {
	t.Parallel()
	prov := signintest.NewProvider(t, "RS256", "")
	st, key, keeper := store.NewMemory(), controllink.NewPrivateKey(), newKeeperKey()
	change := func(c *Config) {
		withKeeper(keeper)(c)
		c.SignIn = &signin.Config{HTTP: prov.HTTP()}
	}
	a, b := startCopyWith(t, st, key, change), startCopyWith(t, st, key, change)
	a.waitFor(func() bool { return len(a.s.mesh.peers()) == 1 && len(b.s.mesh.peers()) == 1 }, "the copies linked")
	_, owner := a.client("Alex's Mac")
	addOrg(t, owner, prov, wire.OrgProviderJoinAnyone)
	s := openSignIn(t, a)
	start := orgStartOn(t, s, wire.SignInOrgReturnApp)
	// The browser lands at b: b sends it to the provider, which comes back to b.
	v := (&browser{prov: prov}).open(t, strings.Replace(start, a.url, b.url, 1))
	if err := ticketOn(s, v.Get("ticket"), wire.ClientKindMac); err != nil {
		t.Fatal(err)
	}
	// Another control plane over another store knows no such ticket (SC-004).
	other, _, otherOwner, _ := orgPlane(t, prov, nil)
	addOrg(t, otherOwner, prov, wire.OrgProviderJoinAnyone)
	there := openSignIn(t, other)
	v = (&browser{prov: prov}).open(t, orgStartOn(t, openSignIn(t, a), wire.SignInOrgReturnApp))
	if err := ticketOn(there, v.Get("ticket"), wire.ClientKindMac); err == nil || !strings.Contains(err.Error(), "not known") {
		t.Fatal(err)
	}
}

// T005, D10: Who may join. Only by invite refuses a person nobody knows; anyone joins as a
// member; an invited person adds the org sign-in and stays one person (US2 AS5, AS6).
func TestWhoMayJoinByAnOrgProvider(t *testing.T) {
	t.Parallel()
	prov := signintest.NewProvider(t, "RS256", "")
	p, _, owner, _ := orgPlane(t, prov, nil)
	addOrg(t, owner, prov, wire.OrgProviderJoinInvite)
	b := &browser{prov: prov}
	prov.SignInAs(signintest.Claims{"sub": "00u-kim", "email": "kim@acme.test", "name": "Kim"})
	if _, err := p.signInOrg(t, b); err == nil || !strings.Contains(err.Error(), "Ask an admin of this control plane for an invite") {
		t.Fatal(err)
	}
	// Kim is invited, pairs with the code, and adds the org sign-in from that client.
	kim := p.invite(owner, "Kim", wire.UserRoleMember)
	var started wire.SignInOrgStarted
	json.Unmarshal(call(t, kim.window, "", "signIn/orgStart", wire.SignInOrgStart{Provider: "acme-okta", Purpose: wire.SignInOrgPurposeAddToMe,
		ReturnTo: wire.SignInOrgReturnApp}), &started)
	v := b.open(t, started.URL)
	// Another of the owner's clients cannot take Kim's ticket.
	if e := callError(t, owner, "", "signIn/ticket", wire.SignInTicket{Ticket: v.Get("ticket")}); !strings.Contains(e, "another connection") {
		t.Fatal(e)
	}
	var added wire.SignInTicketResult
	json.Unmarshal(call(t, kim.window, "", "signIn/ticket", wire.SignInTicket{Ticket: v.Get("ticket")}), &added)
	if added.SignIn == nil || added.SignIn.Provider != "acme-okta" || deref(added.SignIn.Account) != "00u-kim" {
		t.Fatalf("%+v", added)
	}
	member, err := p.signInOrg(t, b)
	if err != nil || personOf(t, p, member) != kim.id {
		t.Fatal(err)
	}
	if n := len(p.s.records.People()); n != 2 {
		t.Fatalf("%d people", n)
	}
	// Anyone the provider signs in joins as a member.
	var list wire.OrgProviderList
	json.Unmarshal(call(t, owner, "", "signIn/orgProviders/list", nil), &list)
	o := list.Providers[0].Provider
	o.Join = new(wire.OrgProviderJoinAnyone)
	call(t, owner, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: o, Rev: &list.Providers[0].Rev})
	prov.SignInAs(signintest.Claims{"sub": "00u-lee", "email": "lee@acme.test"})
	lee, err := p.signInOrg(t, b)
	if err != nil {
		t.Fatal(err)
	}
	if got := p.s.records.Person(personOf(t, p, lee)); got.Name != "lee" || got.Role != records.RoleMember {
		t.Fatalf("%+v", got)
	}
	// Turned off, it signs nobody in (FR-009).
	json.Unmarshal(call(t, owner, "", "signIn/orgProviders/list", nil), &list)
	o = list.Providers[0].Provider
	o.On = new(false)
	call(t, owner, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: o, Rev: &list.Providers[0].Rev})
	if _, err := p.signInOrg(t, b); err == nil {
		t.Fatal("a provider turned off signed in")
	}
}

// T006, D8, D9, FR-010 to FR-012: a domain claimed, proved by TXT, sending people and
// requiring its provider at join, pair and renewal; never the local owner; the daily
// check takes a lost domain back after 7 days.
func TestClaimedDomainsSendAndRequire(t *testing.T) {
	t.Parallel()
	prov := signintest.NewProvider(t, "RS256", "")
	f := newProvidersFake(t)
	p, m, owner, dns := orgPlane(t, prov, f)
	addOrg(t, owner, prov, wire.OrgProviderJoinInvite)
	// Kim signs in with Google at acme.test before the domain is required.
	kim := p.invite(owner, "Kim", wire.UserRoleMember)
	googleKim := func(n string) string {
		return f.mint(signin.Google, "kim-google", n, signintest.Claims{"email": "kim@acme.test", "email_verified": true})
	}
	if _, e := addToMe(t, kim.window, kim.member, signin.Google, googleKim); e != "" {
		t.Fatal(e)
	}
	// The local owner has a Google sign-in at acme.test too.
	if _, e := addToMe(t, owner, m, signin.Google, func(n string) string {
		return f.mint(signin.Google, "alex-google", n, signintest.Claims{"email": "alex@acme.test", "email_verified": true})
	}); e != "" {
		t.Fatal(e)
	}

	var claim wire.DomainClaim
	json.Unmarshal(call(t, owner, "", "signIn/domains/claim", wire.SignInDomainClaim{Domain: "Acme.Test", Provider: "acme-okta"}), &claim)
	if claim.Domain != "acme.test" || claim.TxtName != "_agents.acme.test" || !strings.HasPrefix(claim.TxtValue, "agents-domain=") ||
		len(claim.TxtValue) != len("agents-domain=")+32 || claim.State != wire.DomainClaimStateNotProved {
		t.Fatalf("%+v", claim)
	}
	if e := callError(t, kim.window, "", "signIn/domains/claim", wire.SignInDomainClaim{Domain: "kim.test", Provider: "acme-okta"}); !strings.Contains(e, "Only an admin") {
		t.Fatal(e)
	}
	// Not proved: neither switch (US3 AS1).
	if e := callError(t, owner, "", "signIn/domains/set", wire.SignInDomainSet{Domain: "acme.test", Require: new(true)}); !strings.Contains(e, "Prove acme.test first") {
		t.Fatal(e)
	}
	json.Unmarshal(call(t, owner, "", "signIn/domains/check", wire.SignInDomainRequest{Domain: "acme.test"}), &claim)
	if claim.State != wire.DomainClaimStateNotProved {
		t.Fatalf("proved with no record: %+v", claim)
	}
	dns.set(claim.TxtName, "v=spf1", claim.TxtValue)
	json.Unmarshal(call(t, owner, "", "signIn/domains/check", wire.SignInDomainRequest{Domain: "acme.test"}), &claim)
	if claim.State != wire.DomainClaimStateProved || claim.LastGood == nil {
		t.Fatalf("%+v", claim)
	}
	// One domain, one provider (US3 AS5).
	other := orgProvider(prov, "invite")
	other.Name = "Other Okta"
	call(t, owner, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: other, Secret: &prov.ClientSecret})
	if e := callError(t, owner, "", "signIn/domains/claim", wire.SignInDomainClaim{Domain: "acme.test", Provider: "other-okta"}); !strings.Contains(e, "another provider") {
		t.Fatal(e)
	}
	// The preview names Kim and her Google sign-in, and never the local owner.
	var preview wire.SignInDomainPreview
	json.Unmarshal(call(t, owner, "", "signIn/domains/preview", wire.SignInDomainRequest{Domain: "acme.test"}), &preview)
	if len(preview.People) != 1 || preview.People[0].User != kim.id || deref(preview.People[0].SignIns[0].Email) != "kim@acme.test" {
		t.Fatalf("%+v", preview)
	}
	// Send people here: discover answers for acme.test only, the same for any other.
	json.Unmarshal(call(t, owner, "", "signIn/domains/set", wire.SignInDomainSet{Domain: "acme.test", SendHere: new(true), Require: new(true)}), &claim)
	s := openSignIn(t, p)
	for email, want := range map[string]string{"lee@ACME.test": "acme-okta", "lee@other.test": "", "no email": ""} {
		raw, err := s.Call(context.Background(), "signIn/discover", wire.SignInDiscover{Email: email})
		if err != nil {
			t.Fatal(err)
		}
		var d wire.SignInDiscovered
		json.Unmarshal(raw, &d)
		if deref(d.Provider) != want {
			t.Errorf("%s: %s", email, raw)
		}
	}
	var providers wire.SignInProviders
	json.Unmarshal(call(t, owner, "", "signIn/providers", nil), &providers)
	if !deref(providers.Discover) {
		t.Fatalf("%+v", providers)
	}
	// Require: Kim's Google sign-in cannot pair, and a new Google person at acme.test
	// cannot join; Google elsewhere and the local owner can.
	if _, err := p.signInAs(signin.Google, googleKim, nil); err == nil || !strings.Contains(err.Error(), "-32077") || !strings.Contains(err.Error(), "Acme Okta") {
		t.Fatal(err)
	}
	call(t, owner, "", "signIn/configure", wire.SignInConfigure{Provider: signin.Google, Domains: []string{"acme.test", "other.test"}})
	if _, err := p.signInAs(signin.Google, func(n string) string {
		return f.mint(signin.Google, "new-google", n, signintest.Claims{"hd": "acme.test", "email": "new@acme.test", "email_verified": true})
	}, nil); err == nil || !strings.Contains(err.Error(), "-32077") {
		t.Fatal(err)
	}
	if _, err := p.signInAs(signin.Google, func(n string) string {
		return f.mint(signin.Google, "else-google", n, signintest.Claims{"hd": "other.test", "email": "x@other.test", "email_verified": true})
	}, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := p.signInAs(signin.Google, func(n string) string {
		return f.mint(signin.Google, "alex-google", n, signintest.Claims{"email": "alex@acme.test", "email_verified": true})
	}, nil); err != nil {
		t.Fatalf("the local owner was refused: %v", err)
	}
	// Renewal: Kim's client is not renewed, and keeps working until its key ends; once
	// Kim adds the org sign-in, it renews.
	soon := records.At(time.Now().Add(24 * time.Hour))
	p.s.records.ChangeClient(context.Background(), kim.member.Client, func(c *records.ClientRecord) bool { c.Expires = &soon; return true })
	p.s.renewClient(context.Background(), kim.member.Client)
	if c := p.s.records.Client(kim.member.Client); !c.Expires.Equal(soon.Time) {
		t.Fatalf("renewed: %v", c.Expires)
	}
	call(t, kim.window, "", "control/status", nil)
	prov.SignInAs(signintest.Claims{"sub": "00u-kim", "email": "kim@acme.test"})
	var started wire.SignInOrgStarted
	json.Unmarshal(call(t, kim.window, "", "signIn/orgStart", wire.SignInOrgStart{Provider: "acme-okta", Purpose: wire.SignInOrgPurposeAddToMe,
		ReturnTo: wire.SignInOrgReturnApp, LoginHint: new("kim@acme.test")}), &started)
	v := (&browser{prov: prov}).open(t, started.URL)
	call(t, kim.window, "", "signIn/ticket", wire.SignInTicket{Ticket: v.Get("ticket")})
	if hint := prov.Authorized()[len(prov.Authorized())-1].Get("login_hint"); hint != "kim@acme.test" {
		t.Fatalf("login_hint %q", hint)
	}
	p.s.renewClient(context.Background(), kim.member.Client)
	if c := p.s.records.Client(kim.member.Client); c.Expires.Equal(soon.Time) {
		t.Fatal("not renewed once Kim signs in with the org provider")
	}

	// The daily check: the record goes; a day later it is failing, still proved; 7 days on,
	// the claim is not proved and its switches are off (US3 AS2).
	dns.set(claim.TxtName)
	p.s.signIns.org.skew.Store(int64(25 * time.Hour))
	p.s.signIns.checkDomains(context.Background())
	var list wire.SignInDomainList
	json.Unmarshal(call(t, owner, "", "signIn/domains/list", nil), &list)
	if c := list.Domains[0]; c.State != wire.DomainClaimStateProved || c.FailingSince == nil || !c.Require {
		t.Fatalf("%+v", c)
	}
	p.s.signIns.org.skew.Store(int64(9 * 24 * time.Hour))
	p.s.signIns.checkDomains(context.Background())
	json.Unmarshal(call(t, owner, "", "signIn/domains/list", nil), &list)
	if c := list.Domains[0]; c.State != wire.DomainClaimStateNotProved || c.Require || c.SendHere {
		t.Fatalf("%+v", c)
	}
	p.s.signIns.org.skew.Store(0)
	// Not required now: Kim's Google sign-in pairs again.
	p.s.signIns.forgetClaims()
	if _, err := p.signInAs(signin.Google, googleKim, nil); err != nil {
		t.Fatal(err)
	}
	// Removing the provider takes its claims too.
	call(t, owner, "", "signIn/orgProviders/remove", wire.OrgProviderRequest{ID: "acme-okta"})
	json.Unmarshal(call(t, owner, "", "signIn/domains/list", nil), &list)
	if len(list.Domains) != 0 {
		t.Fatalf("%+v", list)
	}
}

// Entra's preset: the account is oid, and an ID token of another tenant is refused.
// Google Workspace's: hd must be one of the provider's proved domains.
func TestEntraAndGoogleWorkspacePresets(t *testing.T) {
	t.Parallel()
	prov := signintest.NewProvider(t, "RS256", "/tenant-1/v2.0")
	p, _, owner, dns := orgPlane(t, prov, nil)
	entra := wire.OrgProvider{Name: "Acme Okta", Preset: wire.OrgProviderPresetEntra, Issuer: prov.Issuer, ClientID: prov.ClientID,
		Join: new(wire.OrgProviderJoinAnyone)}
	var kept wire.OrgProviderKept
	json.Unmarshal(call(t, owner, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: entra, Secret: &prov.ClientSecret}), &kept)
	if deref(kept.Provider.AccountClaim) != "oid" || deref(kept.Provider.Tenant) != "tenant-1" {
		t.Fatalf("%+v", kept.Provider)
	}
	b := &browser{prov: prov}
	prov.SignInAs(signintest.Claims{"sub": "per-app", "oid": "object-1", "tid": "tenant-2", "name": "Ola"})
	if _, err := p.signInOrg(t, b); err == nil || !strings.Contains(err.Error(), "another Entra tenant") {
		t.Fatal(err)
	}
	prov.SignInAs(signintest.Claims{"sub": "per-app", "oid": "object-1", "tid": "tenant-1", "name": "Ola"})
	member, err := p.signInOrg(t, b)
	if err != nil || !p.s.records.Person(personOf(t, p, member)).HasSignIn("acme-okta", "object-1") {
		t.Fatal(err)
	}

	// Google Workspace with the organisation's own client.
	gw := kept.Provider
	gw.Preset, gw.Tenant, gw.AccountClaim = wire.OrgProviderPresetGoogleWorkspace, nil, new("sub")
	json.Unmarshal(call(t, owner, "", "signIn/orgProviders/set", wire.OrgProviderSet{Provider: gw, Rev: &kept.Rev}), &kept)
	prov.SignInAs(signintest.Claims{"sub": "g-1", "hd": "acme.test", "email": "ola@acme.test"})
	if _, err := p.signInOrg(t, b); err == nil || !strings.Contains(err.Error(), "not in one of this provider's domains") {
		t.Fatal(err)
	}
	var claim wire.DomainClaim
	json.Unmarshal(call(t, owner, "", "signIn/domains/claim", wire.SignInDomainClaim{Domain: "acme.test", Provider: "acme-okta"}), &claim)
	dns.set(claim.TxtName, claim.TxtValue)
	call(t, owner, "", "signIn/domains/check", wire.SignInDomainRequest{Domain: "acme.test"})
	if _, err := p.signInOrg(t, b); err != nil {
		t.Fatal(err)
	}
	if hd := prov.Authorized()[len(prov.Authorized())-1].Get("hd"); hd != "acme.test" {
		t.Fatalf("hd %q", hd)
	}
	prov.SignInAs(signintest.Claims{"sub": "g-2", "hd": "evil.test", "email": "x@evil.test"})
	if _, err := p.signInOrg(t, b); err == nil {
		t.Fatal("another Workspace domain signed in")
	}
}

// FR-027: the web page's flow leaves the page in the same tab, and so its connection. Its
// ticket is bound to the page's key and the s: id it proved, so the page pairs with it on a
// new connection with the same key, and nothing else does.
func TestTheWebPageComesBackOnANewConnection(t *testing.T) {
	t.Parallel()
	prov := signintest.NewProvider(t, "RS256", "")
	p, _, owner, _ := orgPlane(t, prov, nil)
	addOrg(t, owner, prov, wire.OrgProviderJoinAnyone)
	b := &browser{prov: prov}
	open := func(id string, private []byte) *controllink.SignInSession {
		t.Helper()
		s, err := controllink.OpenSignInAs(context.Background(), p.url, "", nil, records.KindBrowser, id, private)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(s.Close)
		return s
	}
	first := openSignIn(t, p)
	v := b.open(t, orgStartOn(t, first, wire.SignInOrgReturnWeb))
	first.Close()
	// Another key under the same id, and the same key under another id, are another page.
	if err := ticketOn(open(first.ID(), controllink.NewPrivateKey()), v.Get("ticket"), wire.ClientKindBrowser); err == nil ||
		!strings.Contains(err.Error(), "another connection") {
		t.Fatal(err)
	}
	if err := ticketOn(open("1F0C2E0A-5B7D-4E6A-9C1B-3D2E4F5A6B7C", first.Private()), v.Get("ticket"), wire.ClientKindBrowser); err == nil ||
		!strings.Contains(err.Error(), "another connection") {
		t.Fatal(err)
	}
	back := open(first.ID(), first.Private())
	if err := ticketOn(back, v.Get("ticket"), wire.ClientKindBrowser); err != nil {
		t.Fatal(err)
	}
	if c := p.s.records.Client(strings.ToUpper(first.ID())); c == nil || c.Kind != records.KindBrowser {
		t.Fatalf("%+v", c)
	}
	// The app's flow stays bound to its connection: the same key on a new one is refused.
	app := openSignIn(t, p)
	v = b.open(t, orgStartOn(t, app, wire.SignInOrgReturnApp))
	if err := ticketOn(open(app.ID(), app.Private()), v.Get("ticket"), wire.ClientKindMac); err == nil ||
		!strings.Contains(err.Error(), "another connection") {
		t.Fatal(err)
	}
}

// FR-027 on the page on this domain (#1459): its socket takes an s: as well as a c: and a
// p:, so the page signs in with its org provider and comes back to pair. This Mac's
// loopback listener still takes none.
func TestThePageOnThisDomainSignsIn(t *testing.T) {
	t.Parallel()
	dist := t.TempDir()
	index := []byte("<html></html>")
	sum := sha256.Sum256(index)
	os.WriteFile(filepath.Join(dist, "index.html"), index, 0o644)
	os.WriteFile(filepath.Join(dist, "MANIFEST"), []byte("agents-web 1\nout "+hex.EncodeToString(sum[:])+" Web/dist/index.html\n"), 0o644)
	prov := signintest.NewProvider(t, "RS256", "")
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) {
		withKeeper(newKeeperKey())(c)
		c.SignIn = &signin.Config{HTTP: prov.HTTP()}
		c.PublicWeb = dist
	})
	_, owner := p.client("Alex's Mac")
	addOrg(t, owner, prov, wire.OrgProviderJoinAnyone)
	b := &browser{prov: prov}
	private, id := controllink.NewPrivateKey(), "6A1C3E0B-2D4F-4A6B-8C1D-3E5F7A9B0C2D"
	first, err := controllink.OpenPageSignIn(context.Background(), p.url, records.KindBrowser, id, private)
	if err != nil {
		t.Fatal(err)
	}
	v := b.open(t, orgStartOn(t, first, wire.SignInOrgReturnWeb))
	first.Close()
	back, err := controllink.OpenPageSignIn(context.Background(), p.url, records.KindBrowser, id, private)
	if err != nil {
		t.Fatal(err)
	}
	defer back.Close()
	if err := ticketOn(back, v.Get("ticket"), wire.ClientKindBrowser); err != nil {
		t.Fatal(err)
	}
	if c := p.s.records.Client(id); c == nil || c.Kind != records.KindBrowser {
		t.Fatalf("%+v", c)
	}
}
