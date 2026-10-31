// Package signintest is a fake Google or Apple (an issuer with a JWKS) and a fake GitHub
// API, for tests of sign-in (#995). Nothing here is used outside tests.
package signintest

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Issuer is a fake OIDC issuer: it serves its JWKS and mints ID tokens.
type Issuer struct {
	Server *httptest.Server
	Issuer string
	// Fetches counts the JWKS fetched.
	Fetches atomic.Int64
	// Down makes the JWKS answer 503.
	Down atomic.Bool

	mu   sync.Mutex
	key  *rsa.PrivateKey
	kid  string
	keys map[string]*rsa.PrivateKey
}

// NewIssuer starts a fake issuer that names itself iss.
func NewIssuer(t *testing.T, iss string) *Issuer {
	i := &Issuer{Issuer: iss, keys: map[string]*rsa.PrivateKey{}}
	i.Rotate()
	i.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		i.Fetches.Add(1)
		if i.Down.Load() {
			http.Error(w, "down", http.StatusServiceUnavailable)
			return
		}
		i.mu.Lock()
		defer i.mu.Unlock()
		set := []map[string]string{}
		for kid, k := range i.keys {
			set = append(set, map[string]string{"kty": "RSA", "kid": kid, "use": "sig", "alg": "RS256",
				"n": b64(k.N.Bytes()), "e": b64(big.NewInt(int64(k.E)).Bytes())})
		}
		json.NewEncoder(w).Encode(map[string]any{"keys": set})
	}))
	t.Cleanup(i.Server.Close)
	return i
}

// JWKS is the address of the issuer's keys.
func (i *Issuer) JWKS() string { return i.Server.URL + "/keys" }

// Rotate makes a new signing key, as a provider does; the old one stays in the JWKS.
func (i *Issuer) Rotate() {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		panic(err)
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	kid := b64(sha(key.N.Bytes())[:8])
	i.key, i.kid, i.keys[kid] = key, kid, key
}

// Claims are an ID token's claims; Mint fills iss, iat and exp when they are not set.
type Claims map[string]any

// Mint signs claims with the issuer's newest key.
func (i *Issuer) Mint(c Claims) string {
	i.mu.Lock()
	key, kid := i.key, i.kid
	i.mu.Unlock()
	return MintWith(key, kid, "RS256", i.complete(c))
}

func (i *Issuer) complete(c Claims) Claims {
	out := Claims{"iss": i.Issuer, "iat": time.Now().Unix(), "exp": time.Now().Add(time.Hour).Unix()}
	for k, v := range c {
		out[k] = v
	}
	return out
}

// MintWith signs claims with any key, as a forger would.
func MintWith(key *rsa.PrivateKey, kid, alg string, c Claims) string {
	header, _ := json.Marshal(map[string]string{"alg": alg, "kid": kid, "typ": "JWT"})
	body, _ := json.Marshal(c)
	signing := b64(header) + "." + b64(body)
	if alg == "none" {
		return signing + "."
	}
	digest := sha(([]byte)(signing))
	signature, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest)
	if err != nil {
		panic(err)
	}
	return signing + "." + b64(signature)
}

// Forge signs claims with a key that is not the issuer's, under the issuer's key id.
func (i *Issuer) Forge(c Claims) string {
	other, _ := rsa.GenerateKey(rand.Reader, 2048)
	i.mu.Lock()
	kid := i.kid
	i.mu.Unlock()
	return MintWith(other, kid, "RS256", i.complete(c))
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func sha(b []byte) []byte {
	s := sha256.Sum256(b)
	return s[:]
}

// GitHub is a fake GitHub API: GET /user and GET /user/memberships/orgs/<org>, by token.
type GitHub struct {
	Server *httptest.Server
	// Down makes every call answer 503.
	Down atomic.Bool

	mu    sync.Mutex
	users map[string]githubUser
	// Seen is every token the fake was asked with, to check what the control plane sent.
	seen []string
}

type githubUser struct {
	id    int64
	login string
	orgs  []string
}

// NewGitHub starts a fake GitHub API.
func NewGitHub(t *testing.T) *GitHub {
	g := &GitHub{users: map[string]githubUser{}}
	g.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if g.Down.Load() {
			http.Error(w, "down", http.StatusServiceUnavailable)
			return
		}
		token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		g.mu.Lock()
		g.seen = append(g.seen, token)
		u, ok := g.users[token]
		g.mu.Unlock()
		if !ok {
			http.Error(w, `{"message":"Bad credentials"}`, http.StatusUnauthorized)
			return
		}
		switch {
		case r.URL.Path == "/user":
			json.NewEncoder(w).Encode(map[string]any{"id": u.id, "login": u.login, "type": "User"})
		case strings.HasPrefix(r.URL.Path, "/user/memberships/orgs/"):
			org := strings.TrimPrefix(r.URL.Path, "/user/memberships/orgs/")
			for _, o := range u.orgs {
				if strings.EqualFold(o, org) {
					json.NewEncoder(w).Encode(map[string]any{"state": "active"})
					return
				}
			}
			http.Error(w, `{"message":"Not Found"}`, http.StatusNotFound)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(g.Server.Close)
	return g
}

// Token makes a token for a GitHub user in the organisations given.
func (g *GitHub) Token(id int64, login string, orgs ...string) string {
	b := make([]byte, 16)
	rand.Read(b)
	token := "ghu_" + b64(b)
	g.mu.Lock()
	g.users[token] = githubUser{id, login, orgs}
	g.mu.Unlock()
	return token
}

// Revoke makes a token fail, as an expired one does.
func (g *GitHub) Revoke(token string) {
	g.mu.Lock()
	delete(g.users, token)
	g.mu.Unlock()
}

// Seen is how many times the fake was asked with the token.
func (g *GitHub) Seen(token string) int {
	g.mu.Lock()
	defer g.mu.Unlock()
	n := 0
	for _, s := range g.seen {
		if s == token {
			n++
		}
	}
	return n
}
