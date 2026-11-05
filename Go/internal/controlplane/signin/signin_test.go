package signin_test

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/signin"
	"github.com/alexec/agents/Go/internal/controlplane/signin/signintest"
)

const app = "app-client-id.apps.example"

func google(t *testing.T) (*signintest.Issuer, *signin.OIDC) {
	issuer := signintest.NewIssuer(t, "https://accounts.google.com")
	o := signin.GoogleOIDC([]string{app})
	o.JWKSURL = issuer.JWKS()
	return issuer, o
}

func TestAGoodIDTokenNamesItsPerson(t *testing.T) {
	issuer, o := google(t)
	nonce := signin.Nonce("key1", []byte("hello-nonce"))
	got, err := o.Check(context.Background(), issuer.Mint(signintest.Claims{"sub": "1234", "aud": app, "nonce": nonce,
		"email": "sam@example.com", "email_verified": true, "hd": "example.com", "name": "Sam"}), nonce)
	if err != nil {
		t.Fatal(err)
	}
	if got.Subject != "1234" || got.Email != "sam@example.com" || !got.EmailVerified || got.Domain != "example.com" || got.Name != "Sam" {
		t.Fatalf("%+v", got)
	}
	// aud as a list, as some issuers write it.
	if _, err := o.Check(context.Background(), issuer.Mint(signintest.Claims{"sub": "1", "aud": []string{"x", app}, "nonce": nonce}), nonce); err != nil {
		t.Fatal(err)
	}
}

// Every refusal (#995): a bad signature, another issuer, another app, expired, a nonce
// for another connection or control plane, alg none and a key the JWKS does not have.
func TestEveryBadIDTokenIsRefused(t *testing.T) {
	issuer, o := google(t)
	nonce := signin.Nonce("key1", []byte("hello-nonce"))
	good := signintest.Claims{"sub": "1234", "aud": app, "nonce": nonce}
	with := func(k string, v any) signintest.Claims {
		c := signintest.Claims{}
		for a, b := range good {
			c[a] = b
		}
		if v == nil {
			delete(c, k)
		} else {
			c[k] = v
		}
		return c
	}
	stranger, _ := rsa.GenerateKey(rand.Reader, 2048)
	cases := map[string]struct {
		token string
		nonce string
		want  string
	}{
		"bad signature":        {issuer.Forge(good), nonce, "signature"},
		"tampered":             {tamper(issuer.Mint(good)), nonce, "signature"},
		"alg none":             {signintest.MintWith(stranger, "x", "none", with("iss", issuer.Issuer)), nonce, "RS256"},
		"unknown key":          {signintest.MintWith(stranger, "nope", "RS256", with("iss", issuer.Issuer)), nonce, "signature"},
		"wrong issuer":         {issuer.Mint(with("iss", "https://evil.example")), nonce, "not from google"},
		"wrong aud":            {issuer.Mint(with("aud", "another-app")), nonce, "another app"},
		"expired":              {issuer.Mint(with("exp", time.Now().Add(-10*time.Minute).Unix())), nonce, "expired"},
		"from the future":      {issuer.Mint(with("iat", time.Now().Add(time.Hour).Unix())), nonce, "future"},
		"no nonce":             {issuer.Mint(with("nonce", nil)), nonce, "another sign-in"},
		"replayed nonce":       {issuer.Mint(with("nonce", signin.Nonce("key1", []byte("an earlier hello")))), nonce, "another sign-in"},
		"other control plane":  {issuer.Mint(with("nonce", signin.Nonce("key2", []byte("hello-nonce")))), nonce, "another sign-in"},
		"no nonce to check":    {issuer.Mint(good), "", "another sign-in"},
		"names nobody":         {issuer.Mint(with("sub", nil)), nonce, "nobody"},
		"not a token":          {"abc.def", nonce, "not an ID token"},
	}
	for name, c := range cases {
		_, err := o.Check(context.Background(), c.token, c.nonce)
		if !signin.IsRefused(err) || !strings.Contains(strings.ToLower(err.Error()), strings.ToLower(c.want)) {
			t.Errorf("%s: %v", name, err)
		}
	}
}

// Within 5 minutes of skew a token still works; a token just past its expiry, too.
func TestClockSkewOfFiveMinutesIsAllowed(t *testing.T) {
	issuer, o := google(t)
	nonce := signin.Nonce("k", []byte("n"))
	token := issuer.Mint(signintest.Claims{"sub": "1", "aud": app, "nonce": nonce, "exp": time.Now().Add(-4 * time.Minute).Unix()})
	if _, err := o.Check(context.Background(), token, nonce); err != nil {
		t.Fatal(err)
	}
}

// A provider's new key works with no restart; while the issuer is down, the keys kept
// still check, and a key not kept says sign-in is not available.
func TestTheProviderRotatesItsKeys(t *testing.T) {
	issuer, o := google(t)
	nonce := signin.Nonce("k", []byte("n"))
	now := time.Now()
	o.Now = func() time.Time { return now }
	claims := func() signintest.Claims {
		return signintest.Claims{"sub": "1", "aud": app, "nonce": nonce, "iat": now.Unix(), "exp": now.Add(time.Hour).Unix()}
	}
	if _, err := o.Check(context.Background(), issuer.Mint(claims()), nonce); err != nil {
		t.Fatal(err)
	}
	issuer.Rotate()
	// Within a minute an unknown key id fetches nothing: a stream of made-up ids cannot
	// hammer the provider.
	fetches := issuer.Fetches.Load()
	if _, err := o.Check(context.Background(), issuer.Mint(claims()), nonce); !signin.IsRefused(err) || issuer.Fetches.Load() != fetches {
		t.Fatalf("%v, %d fetches", err, issuer.Fetches.Load()-fetches)
	}
	now = now.Add(2 * time.Minute)
	if _, err := o.Check(context.Background(), issuer.Mint(claims()), nonce); err != nil {
		t.Fatal(err)
	}
	issuer.Down.Store(true)
	now = now.Add(2 * time.Hour)
	if _, err := o.Check(context.Background(), issuer.Mint(claims()), nonce); err != nil {
		t.Fatalf("a kept key while the issuer is down: %v", err)
	}
	issuer.Rotate()
	if _, err := o.Check(context.Background(), issuer.Mint(claims()), nonce); !signin.IsUnavailable(err) || !strings.Contains(err.Error(), "not available") {
		t.Fatalf("%v", err)
	}
}

func TestTheNonceIsBoundToTheKeyAndTheHello(t *testing.T) {
	a := signin.Nonce("key1", []byte("hello"))
	if a != signin.Nonce("key1", []byte("hello")) || a == signin.Nonce("key2", []byte("hello")) || a == signin.Nonce("key1", []byte("hellO")) ||
		len(a) != 64 {
		t.Fatal(a)
	}
}

func TestGitHubNamesItsUserByNumericID(t *testing.T) {
	fake := signintest.NewGitHub(t)
	g := &signin.GitHubAPI{Base: fake.Server.URL}
	token := fake.Token(42, "sam", "acme")
	u, err := g.User(context.Background(), token)
	if err != nil || u.ID != "42" || u.Login != "sam" {
		t.Fatalf("%+v %v", u, err)
	}
	if in, err := g.InOrganisation(context.Background(), token, "acme"); !in || err != nil {
		t.Fatal(in, err)
	}
	if in, err := g.InOrganisation(context.Background(), token, "other"); in || err != nil {
		t.Fatal(in, err)
	}
	fake.Revoke(token)
	if _, err := g.User(context.Background(), token); !signin.IsRefused(err) {
		t.Fatal(err)
	}
	fake.Down.Store(true)
	if _, err := g.User(context.Background(), fake.Token(1, "x")); !signin.IsUnavailable(err) {
		t.Fatal(err)
	}
	if _, err := g.User(context.Background(), ""); !signin.IsRefused(err) {
		t.Fatal(err)
	}
}

func tamper(token string) string {
	parts := strings.Split(token, ".")
	parts[1] = parts[1][:len(parts[1])-2] + "AA"
	return strings.Join(parts, ".")
}
