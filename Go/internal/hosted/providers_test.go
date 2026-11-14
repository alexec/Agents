package hosted

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/controllink"
	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/records"
	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/signin"
	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/signin/signintest"
	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The app's own ids, as each account's control plane checks a native sign-in.
const (
	googleApp = "google-app.apps.example"
	appleApp  = "com.alexecollins.agents.remote"
)

// signUps is a hosted service with Apple and Google on the web (fakes of each), GitHub's
// fake, and fakes of all three as each account's control plane checks them.
type signUps struct {
	s          *Service
	server     *httptest.Server
	newBrowser func() *browser
	apple      *signintest.Provider
	google     *signintest.Provider
	// What the control planes check: a native sign-in's ID tokens, and GitHub's API.
	appleApp, googleApp *signintest.Issuer
	gitHubApp           *signintest.GitHub
}

func startSignUps(t *testing.T, st store.Store, mode string) *signUps {
	t.Helper()
	u := &signUps{apple: signintest.NewProvider(t, "RS256", ""), google: signintest.NewProvider(t, "RS256", ""),
		appleApp: signintest.NewIssuer(t, "https://appleid.apple.com"), googleApp: signintest.NewIssuer(t, "https://accounts.google.com"),
		gitHubApp: signintest.NewGitHub(t)}
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	p8 := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	// Apple's client secret is a JWT signed with the team's key, for the Services ID.
	u.apple.NoPKCE.Store(true)
	u.apple.CheckSecret(func(secret string) bool { return appleSecretOK(secret, &key.PublicKey, u.apple.ClientID) })
	at := func(p *signintest.Provider) Endpoints {
		return Endpoints{Issuer: p.Issuer, Authorize: p.Issuer + "/authorize", Token: p.Issuer + "/token", JWKS: p.Issuer + "/keys"}
	}
	cfg := Config{Store: st, SignUp: mode, SignUpsPerAddress: 100,
		AppleServicesID: u.apple.ClientID, AppleTeamID: "TEAM123456", AppleKeyID: "KEY1234567", AppleKey: p8,
		GoogleClientID: u.google.ClientID, GoogleSecret: u.google.ClientSecret,
		AppleAt: at(u.apple), GoogleAt: at(u.google), SignInHTTP: u.apple.HTTP(),
		CopySignIn: &signin.Config{GoogleClientIDs: []string{googleApp}, AppleAudiences: []string{appleApp}, AppleEnabled: true,
			GitHubClientID: "Iv1.github-app", GoogleJWKS: u.googleApp.JWKS(), AppleJWKS: u.appleApp.JWKS(), GitHubAPI: u.gitHubApp.Server.URL}}
	u.s, u.newBrowser, u.server = startServing(t, cfg)
	return u
}

// appleSecretOK checks an Apple client secret as Apple does: ES256 by the team's key, for
// the Services ID, made just now.
func appleSecretOK(secret string, key *ecdsa.PublicKey, servicesID string) bool {
	parts := strings.Split(secret, ".")
	if len(parts) != 3 {
		return false
	}
	var header, claims map[string]any
	h, _ := base64.RawURLEncoding.DecodeString(parts[0])
	c, _ := base64.RawURLEncoding.DecodeString(parts[1])
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	if json.Unmarshal(h, &header) != nil || json.Unmarshal(c, &claims) != nil || len(sig) != 64 {
		return false
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if !ecdsa.Verify(key, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		return false
	}
	exp, _ := claims["exp"].(float64)
	return header["alg"] == "ES256" && header["kid"] == "KEY1234567" && claims["iss"] == "TEAM123456" &&
		claims["sub"] == servicesID && claims["aud"] == "https://appleid.apple.com" && time.Unix(int64(exp), 0).After(time.Now())
}

// signUpWith goes from the sign-up page's button to the provider and back, and says where
// the service sent the browser.
func (u *signUps) signUpWith(t *testing.T, b *browser, provider, invite string) *http.Response {
	t.Helper()
	from := "https://" + domain + "/signin?with=" + provider
	if invite != "" {
		from += "&invite=" + invite
	}
	res, _ := b.get(from)
	to := res.Header.Get("Location")
	if res.StatusCode != http.StatusSeeOther {
		t.Fatalf("%d %s", res.StatusCode, b.last)
	}
	return u.backFrom(t, b, provider, to)
}

// backFrom is the provider at to signing the person in and sending the browser back: by a
// form post from Apple, which is asked for an email (#3388), by a redirect from the others.
func (u *signUps) backFrom(t *testing.T, b *browser, provider, to string) *http.Response {
	t.Helper()
	fake := map[string]*signintest.Provider{signin.Apple: u.apple, signin.Google: u.google}[provider]
	if !strings.HasPrefix(to, fake.Issuer+"/authorize?") {
		t.Fatal(to)
	}
	q, _ := url.Parse(to)
	if q.Query().Get("redirect_uri") != "https://"+domain+"/signin/callback" || q.Query().Get("scope") != "openid email" {
		t.Fatal(to)
	}
	formPost := q.Query().Get("response_mode") == "form_post"
	if formPost != (provider == signin.Apple) {
		t.Fatalf("%s: response_mode %q", provider, q.Query().Get("response_mode"))
	}
	c := fake.HTTP()
	c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	back, err := c.Get(to)
	if err != nil {
		t.Fatal(err)
	}
	back.Body.Close()
	if !formPost {
		res, _ := b.get(back.Header.Get("Location"))
		return res
	}
	// Apple posts the answer to the callback from its own page.
	answer, _ := url.Parse(back.Header.Get("Location"))
	callback := *answer
	callback.RawQuery = ""
	res, _ := b.post(callback.String(), answer.Query())
	return res
}

// dialCopy is where a client signs in to the account's control plane: through this
// service at the account's own name, as on the internet, and the pin of its certificate.
func (u *signUps) dialCopy(t *testing.T, id string) (string, string) {
	t.Helper()
	sum := sha256.Sum256(u.server.Certificate().RawSubjectPublicKeyInfo)
	return "https://" + id + "." + domain, controllink.B64URL(sum[:])
}

// #3386: a person signs up with Apple, with Google and with GitHub, each on an invite, and
// then signs in to their own control plane with the same provider: its first person, an
// admin, has that sign-in, and the provider is on there.
func TestSignUpWithEachProviderAndSignInToTheControlPlane(t *testing.T) {
	st := store.NewMemory()
	u := startSignUps(t, st, SignUpInvite)
	proxyTo(t, u.server.Listener.Addr().String())
	_, page := u.newBrowser().get("https://" + domain + "/")
	apple, google, github := strings.Index(page, "Sign Up with Apple"), strings.Index(page, "Sign Up with Google"), strings.Index(page, "Sign Up with GitHub")
	if apple < 0 || google < apple || github < google || !strings.Contains(page, `href="/signin?with=apple"`) {
		t.Fatal(page)
	}
	admin := Admin{Store: st, Domain: domain}
	subjects := map[string]string{signin.Apple: "001234.0a1b2c3d4e5f.0987", signin.Google: "109876543210987654321", signin.GitHub: "42"}
	for _, provider := range signin.Providers {
		link, err := admin.Invite(context.Background(), 0)
		if err != nil {
			t.Fatal(err)
		}
		invite := strings.TrimPrefix(link, "https://"+domain+"/?invite=")
		b := u.newBrowser()
		if _, page := b.get(link); !strings.Contains(page, "/signin?with="+provider+"&amp;invite="+invite) {
			t.Fatal(page)
		}
		var res *http.Response
		switch provider {
		case signin.Apple:
			u.apple.SignInAs(signintest.Claims{"sub": subjects[provider]})
			res = u.signUpWith(t, b, provider, invite)
		case signin.Google:
			u.google.SignInAs(signintest.Claims{"sub": subjects[provider], "email": "sam@example.com"})
			res = u.signUpWith(t, b, provider, invite)
		default:
			res = b.signInWith("good", invite)
		}
		if !strings.Contains(res.Header.Get("Location"), "/#code=") {
			t.Fatalf("%s: %d %s %s", provider, res.StatusCode, res.Header.Get("Location"), b.last)
		}
		acc, _ := u.s.accounts.bySignIn(context.Background(), SignIn{Provider: provider, Subject: subjects[provider]})
		if acc == nil {
			t.Fatalf("%s: no account", provider)
		}
		// Nothing but the subject is kept, and GitHub's login.
		if o, _ := st.Get(context.Background(), accountKey(acc.ID)); strings.Contains(string(o.Data), "sam@example.com") {
			t.Fatalf("%s: the email was kept: %s", provider, o.Data)
		}
		_, page := b.get("https://" + domain + "/account")
		if want := map[string]string{signin.Apple: "Signed in with Apple.", signin.Google: "Signed in with Google.",
			signin.GitHub: "Signed in with GitHub as ana."}[provider]; !strings.Contains(page, want) {
			t.Fatalf("%s: %s", provider, page)
		}

		// The person signs in to their control plane with the same provider, from a phone.
		base, pin := u.dialCopy(t, acc.ID)
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		waited := false
		m, err := controllink.SignIn(ctx, base, pin, nil, "Sam's iPhone", records.KindIPhone,
			func(providers wire.SignInProviders, nonce string) (string, string, error) {
				switch provider {
				case signin.Apple:
					return provider, u.appleApp.Mint(signintest.Claims{"sub": subjects[provider], "aud": appleApp, "nonce": nonce}), nil
				case signin.Google:
					return provider, u.googleApp.Mint(signintest.Claims{"sub": subjects[provider], "aud": googleApp, "nonce": nonce}), nil
				}
				return provider, u.gitHubApp.Token(42, "ana"), nil
			}, func(wire.SignInWaiting) {
				// A GitHub sign-in is known, and waits for Approve on another of the person's
				// clients (#995 R3): this browser's, once it pairs.
				waited = true
				cancel()
			})
		cancel()
		c := u.s.inUse(acc.ID)
		if c == nil {
			t.Fatalf("%s: the copy is not running", provider)
		}
		owner := *c.service.Records().Settings().Owner
		p := c.service.Records().Person(owner)
		u.s.done(c)
		if p == nil || !p.IsAdmin() || !p.HasSignIn(provider, subjects[provider]) {
			t.Fatalf("%s: the first person is %+v", provider, p)
		}
		if provider == signin.GitHub {
			if !waited {
				t.Fatalf("github: %v", err)
			}
			continue
		}
		if err != nil {
			t.Fatalf("%s: %v", provider, err)
		}
		c = u.s.inUse(acc.ID)
		person := c.service.PersonOf(m.Client)
		u.s.done(c)
		if person != owner {
			t.Fatalf("%s: paired as %s, not the first person %s", provider, person, owner)
		}
	}
}

// #3388: open sign-up needs an email the provider verified, Google's email_verified,
// Apple's email (a private relay address too) or GitHub's verified primary; with none,
// refused with words, and nobody waits. With an invite, no email is needed.
func TestOpenSignUpNeedsAVerifiedEmail(t *testing.T) {
	st := store.NewMemory()
	ctx := context.Background()
	u := startSignUps(t, st, SignUpOpen)
	if _, page := u.newBrowser().get("https://" + domain + "/"); !strings.Contains(page, "verified") || strings.Contains(page, "by invitation") {
		t.Fatal(page)
	}
	u.apple.SignInAs(signintest.Claims{"sub": "000111.aaa.222"})
	u.google.SignInAs(signintest.Claims{"sub": "333444", "email": "sam@example.com", "email_verified": false})
	for _, provider := range []string{signin.Apple, signin.Google, signin.GitHub} {
		b := u.newBrowser()
		var res *http.Response
		if provider == signin.GitHub {
			res = b.signIn("u.9.noemail.400")
		} else {
			res = u.signUpWith(t, b, provider, "")
		}
		want := map[string]string{signin.Apple: "Apple gave none", signin.Google: "Google gave none", signin.GitHub: "github.com/settings/emails"}[provider]
		if res.StatusCode != http.StatusForbidden || !strings.Contains(b.last, want) {
			t.Fatalf("%s: %d %s", provider, res.StatusCode, b.last)
		}
	}
	if list, _ := (Admin{Store: st}).Waitlist(ctx); len(list) != 0 {
		t.Fatalf("%+v", list)
	}
	if n, _ := u.s.accounts.count(ctx); n != 0 {
		t.Fatalf("%d accounts", n)
	}

	// Verified: an account each. Apple's relay address is an email, with no email_verified.
	u.apple.SignInAs(signintest.Claims{"sub": "000111.aaa.222", "email": "x7@privaterelay.appleid.com"})
	u.google.SignInAs(signintest.Claims{"sub": "333444", "email": "Sam@Example.com", "email_verified": true})
	for _, provider := range []string{signin.Apple, signin.Google} {
		b := u.newBrowser()
		if res := u.signUpWith(t, b, provider, ""); !strings.Contains(res.Header.Get("Location"), "/#code=") {
			t.Fatalf("%s: %s %s", provider, res.Header.Get("Location"), b.last)
		}
	}
	if res := u.newBrowser().signIn("u.10.lee.400"); !strings.Contains(res.Header.Get("Location"), "/#code=") {
		t.Fatal(res.Header.Get("Location"))
	}
	// Nowhere in the store is an address: only its mark.
	keys, _ := st.List(ctx, "")
	for _, k := range keys {
		o, _ := st.Get(ctx, k.Key)
		if text := strings.ToLower(k.Key + string(o.Data)); strings.Contains(text, "example.com") || strings.Contains(text, "privaterelay") {
			t.Fatalf("an email is kept: %s %s", k.Key, o.Data)
		}
	}

	// With an invite, no email is needed.
	admin := Admin{Store: st, Domain: domain, Keeper: testKeeper}
	link, _ := admin.Invite(ctx, 0)
	u.apple.SignInAs(signintest.Claims{"sub": "000999.bbb.111"})
	b := u.newBrowser()
	if res := u.signUpWith(t, b, signin.Apple, strings.TrimPrefix(link, "https://"+domain+"/?invite=")); !strings.Contains(res.Header.Get("Location"), "/#code=") {
		t.Fatal(res.Header.Get("Location"), b.last)
	}
}

// #3388: one email has one account: a second provider's sign-in with the same verified
// email gets the account it has. Deleting the account lets the email sign up again.
func TestOneAccountPerEmail(t *testing.T) {
	st := store.NewMemory()
	ctx := context.Background()
	u := startSignUps(t, st, SignUpOpen)
	u.google.SignInAs(signintest.Claims{"sub": "333444", "email": "Sam@Example.com", "email_verified": true})
	if res := u.signUpWith(t, u.newBrowser(), signin.Google, ""); !strings.Contains(res.Header.Get("Location"), "/#code=") {
		t.Fatal(res.Header.Get("Location"))
	}
	b := u.newBrowser()
	if res := b.signIn("u.50.sam.400.sam@example.com"); res.Header.Get("Location") != "/account" {
		t.Fatal(res.Header.Get("Location"), b.last)
	}
	if _, page := b.get("https://" + domain + "/account"); !strings.Contains(page, "Signed in with Google.") {
		t.Fatal(page)
	}
	u.apple.SignInAs(signintest.Claims{"sub": "000111.aaa.222", "email": "sam@example.com", "email_verified": "true"})
	if res := u.signUpWith(t, u.newBrowser(), signin.Apple, ""); res.Header.Get("Location") != "/account" {
		t.Fatal(res.Header.Get("Location"))
	}
	if n, _ := u.s.accounts.count(ctx); n != 1 {
		t.Fatalf("%d accounts", n)
	}

	acc, _ := u.s.accounts.bySignIn(ctx, SignIn{Provider: signin.Google, Subject: "333444"})
	if acc == nil || acc.EmailMark == "" {
		t.Fatalf("%+v", acc)
	}
	if err := u.s.accounts.remove(ctx, acc); err != nil {
		t.Fatal(err)
	}
	if o, _ := st.Get(ctx, emailKey(acc.EmailMark)); o != nil {
		t.Fatal("the email's link is kept")
	}
	if res := u.newBrowser().signIn("u.50.sam.400.sam@example.com"); !strings.Contains(res.Header.Get("Location"), "/#code=") {
		t.Fatal(res.Header.Get("Location"))
	}
}

// #3388: a block by sign-in blocks its account's email too, from every provider; a block by
// email needs the keeper, and blocks that email alone. Unblock lets each sign up again.
func TestBlocksByEmail(t *testing.T) {
	st := store.NewMemory()
	ctx := context.Background()
	u := startSignUps(t, st, SignUpOpen)
	u.google.SignInAs(signintest.Claims{"sub": "333444", "email": "spam@example.com", "email_verified": true})
	if res := u.signUpWith(t, u.newBrowser(), signin.Google, ""); !strings.Contains(res.Header.Get("Location"), "/#code=") {
		t.Fatal(res.Header.Get("Location"))
	}
	admin := Admin{Store: st, Domain: domain, Keeper: testKeeper}
	if _, err := admin.Block(ctx, "google:333444", "Spam"); err != nil {
		t.Fatal(err)
	}
	// The same email from GitHub, as a new user: refused, and nothing made.
	b := u.newBrowser()
	if res := b.signIn("u.60.spammer.400.spam@example.com"); res.StatusCode != http.StatusForbidden || !strings.Contains(b.last, "not open to this GitHub account") {
		t.Fatal(res.StatusCode, b.last)
	}
	if err := admin.Unblock(ctx, "google:333444"); err != nil {
		t.Fatal(err)
	}
	if res := u.newBrowser().signIn("u.60.spammer.400.spam@example.com"); res.Header.Get("Location") != "/account" {
		t.Fatal(res.Header.Get("Location"))
	}

	// By email alone: needs the keeper; then refuses it, in any case.
	if _, err := (Admin{Store: st}).Block(ctx, "other@example.com", ""); err == nil {
		t.Fatal("blocked an email with no keeper")
	}
	if who, err := admin.Block(ctx, "Other@Example.com", "Spam"); err != nil || who.Provider != "" {
		t.Fatal(who, err)
	}
	u.apple.SignInAs(signintest.Claims{"sub": "000111.aaa.222", "email": "other@example.com"})
	b = u.newBrowser()
	if res := u.signUpWith(t, b, signin.Apple, ""); res.StatusCode != http.StatusForbidden || !strings.Contains(b.last, "not open to this Apple account") {
		t.Fatal(res.StatusCode, b.last)
	}
	if err := admin.Unblock(ctx, "other@example.com"); err != nil {
		t.Fatal(err)
	}
	if res := u.signUpWith(t, u.newBrowser(), signin.Apple, ""); !strings.Contains(res.Header.Get("Location"), "/#code=") {
		t.Fatal(res.Header.Get("Location"))
	}
}

// #3386: a sign-in that is refused, or one this browser did not start, signs nobody in.
func TestARefusedProviderSignInSignsNobodyIn(t *testing.T) {
	st := store.NewMemory()
	u := startSignUps(t, st, SignUpOpen)
	// A forged ID token.
	u.google.Forge.Store(true)
	b := u.newBrowser()
	if res := u.signUpWith(t, b, signin.Google, ""); res.StatusCode != http.StatusBadGateway || !strings.Contains(b.last, "Google could not be asked") {
		t.Fatal(res.StatusCode, b.last)
	}
	u.google.Forge.Store(false)
	// The person said no at Apple.
	u.apple.Deny("user_cancelled_authorize")
	if res := u.signUpWith(t, b, signin.Apple, ""); !strings.Contains(b.last, "Apple did not sign you in") {
		t.Fatal(res.StatusCode, b.last)
	}
	// A provider that is not set up is not offered.
	if res, _ := b.get("https://" + domain + "/signin?with=okta"); res.StatusCode != http.StatusServiceUnavailable {
		t.Fatal(res.StatusCode)
	}
	if keys, _ := st.List(context.Background(), "hosted/v1/accounts/"); len(keys) != 0 {
		t.Fatalf("%d accounts", len(keys))
	}
}

// #3386: an account made before sign-ins, keyed by its GitHub user, keeps working.
func TestAnAccountFromBeforeSignInsKeepsWorking(t *testing.T) {
	st := store.NewMemory()
	ctx := context.Background()
	old, _ := json.Marshal(map[string]any{"id": "oldaccount", "github": map[string]any{"id": 77, "login": "olga"}, "created": time.Now().UTC()})
	if _, err := st.Put(ctx, "hosted/v1/accounts/oldaccount.json", old, store.Absent); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Put(ctx, "hosted/v1/github/77.json", []byte(`{"account":"oldaccount"}`), store.Absent); err != nil {
		t.Fatal(err)
	}
	_, newBrowser := startWith(t, Config{Store: st})
	b := newBrowser()
	if res := b.signIn("u.77.olga.400"); res.Header.Get("Location") != "/account" {
		t.Fatal(res.Header.Get("Location"), b.last)
	}
	if _, page := b.get("https://" + domain + "/account"); !strings.Contains(page, "Signed in with GitHub as olga.") {
		t.Fatal(page)
	}
	if list, _ := (Admin{Store: st}).Accounts(ctx); len(list) != 1 || list[0].SignIn.String() != "github:77" {
		t.Fatalf("%+v", list)
	}
}

// startServing is startWith, with the TLS server too.
func startServing(t *testing.T, cfg Config) (*Service, func() *browser, *httptest.Server) {
	t.Helper()
	var server *httptest.Server
	s, newBrowser := startWithServer(t, cfg, &server)
	return s, newBrowser, server
}

// proxyTo makes controllink's dials go through a CONNECT proxy to address, as through a
// network's proxy (#2177): an account's name resolves nowhere in a test.
func proxyTo(t *testing.T, address string) {
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodConnect {
			http.Error(w, "CONNECT only", http.StatusMethodNotAllowed)
			return
		}
		up, err := net.Dial("tcp", address)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		down, _, err := http.NewResponseController(w).Hijack()
		if err != nil {
			up.Close()
			return
		}
		_, _ = down.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n"))
		go func() { _, _ = io.Copy(up, down); up.Close() }()
		_, _ = io.Copy(down, up)
		down.Close()
	}))
	t.Cleanup(proxy.Close)
	was := controllink.Proxy
	to, _ := url.Parse(proxy.URL)
	controllink.Proxy = func(*http.Request) (*url.URL, error) { return to, nil }
	t.Cleanup(func() { controllink.Proxy = was })
}

func aged(user SignIn, created time.Time) SignIn {
	user.Created = created
	return user
}

// #3388: with Turnstile's keys, the sign-up page's buttons are one form with the widget,
// and only a token Cloudflare says passed goes on to the provider; a GET of /signin goes
// back to the page. One key alone is an error; with none, there is no Turnstile.
func TestTurnstileOnTheSignUpPage(t *testing.T) {
	cf := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		ok := r.PostForm.Get("secret") == "ts-secret" && r.PostForm.Get("response") == "passed"
		_ = json.NewEncoder(w).Encode(map[string]any{"success": ok, "error-codes": []string{"invalid-input-response"}})
	}))
	t.Cleanup(cf.Close)
	cfg := Config{Store: store.NewMemory(), SignUp: SignUpOpen, TurnstileSiteKey: "ts-site", TurnstileSecret: "ts-secret", TurnstileAPI: cf.URL}
	_, newBrowser := startWith(t, cfg)
	b := newBrowser()
	res, page := b.get("https://" + domain + "/?invite=abcdefghij0123456789")
	csp := res.Header.Get("Content-Security-Policy")
	if !strings.Contains(page, `data-sitekey="ts-site"`) || !strings.Contains(page, `<form class="signup" method="post" action="/signin">`) ||
		!strings.Contains(page, `name="with" value="github"`) || !strings.Contains(page, `name="invite" value="abcdefghij0123456789"`) ||
		!strings.Contains(page, turnstileScript) || strings.Contains(page, `href="/signin?with=`) {
		t.Fatal(page)
	}
	if !strings.Contains(csp, "script-src "+turnstileOrigin) || !strings.Contains(csp, "frame-src "+turnstileOrigin) ||
		!strings.Contains(csp, "form-action 'self' http://127.0.0.1:") {
		t.Fatal(csp)
	}
	if res, _ := b.get("https://" + domain + "/signin?with=github"); res.StatusCode != http.StatusSeeOther || res.Header.Get("Location") != "/" {
		t.Fatal(res.StatusCode, res.Header.Get("Location"))
	}
	for _, token := range []string{"", "failed"} {
		if res, page := b.post("https://"+domain+"/signin", url.Values{"with": {"github"}, turnstileField: {token}}); res.StatusCode != http.StatusForbidden ||
			!strings.Contains(page, "did not pass") {
			t.Fatal(res.StatusCode, page)
		}
	}
	res, _ = b.post("https://"+domain+"/signin", url.Values{"with": {"github"}, turnstileField: {"passed"}})
	to, _ := url.Parse(res.Header.Get("Location"))
	if res.StatusCode != http.StatusSeeOther || to.Path != "/login/oauth/authorize" {
		t.Fatal(res.StatusCode, res.Header.Get("Location"))
	}
	back, _ := b.get("https://" + domain + "/signin/callback?" + url.Values{"code": {"good"}, "state": {to.Query().Get("state")}}.Encode())
	if !strings.Contains(back.Header.Get("Location"), "/#code=") {
		t.Fatal(back.Header.Get("Location"), b.last)
	}

	// Cloudflare down: refused, with words that say to try again.
	cf.Close()
	if res, page := newBrowser().post("https://"+domain+"/signin", url.Values{"with": {"github"}, turnstileField: {"passed"}}); res.StatusCode != http.StatusServiceUnavailable ||
		!strings.Contains(page, "could not be made") {
		t.Fatal(res.StatusCode, page)
	}

	cfg.TurnstileSecret = ""
	cfg.Keeper, cfg.Domain = testKeeper, domain
	if _, err := New(context.Background(), cfg); err == nil || !strings.Contains(err.Error(), "AGENTS_HOSTED_TURNSTILE_SECRET") {
		t.Fatal(err)
	}
}
