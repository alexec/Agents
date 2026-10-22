package signintest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Provider is a fake org OIDC provider (#1002, research R7): an Okta or an Entra on
// loopback, over TLS. It serves its discovery document and JWKS (RS256 or ES256), signs
// in whoever the test says with no consent screen, and answers the token call, which
// checks PKCE and the client secret, and gives an ID token and a refresh token. Nothing
// here is used outside tests.
type Provider struct {
	Server *httptest.Server
	// Issuer is the server's https address, or with a path when made with one.
	Issuer       string
	ClientID     string
	ClientSecret string
	// Alg is what ID tokens are signed with: RS256 or ES256.
	Alg string

	// Down makes every answer 503.
	Down atomic.Bool
	// InvalidGrant makes every refresh answer invalid_grant, as for a person the provider
	// deactivated.
	InvalidGrant atomic.Bool
	// Tokens counts the token calls that gave tokens.
	Tokens atomic.Int64
	// Forge signs ID tokens with a key that is not in the JWKS, under its key id.
	Forge atomic.Bool

	mu sync.Mutex
	// who is the person the next sign-in names, and what the test changes in the ID token.
	who    Claims
	mutate func(Claims)
	deny   string
	// discovery changes the discovery document.
	discovery func(map[string]any)
	codes     map[string]grant
	refreshes map[string]Claims
	rsaKey    *rsa.PrivateKey
	ecKey     *ecdsa.PrivateKey
	kid       string
	// Issued is every token the fake gave: ID, access and refresh tokens.
	issued []string
	// Authorized is the query of each authorize request.
	authorized []url.Values
}

type grant struct {
	claims      Claims
	nonce       string
	challenge   string
	redirectURI string
}

// NewProvider starts a fake org provider with that client and signing algorithm. path is
// added to the issuer, as Okta's /oauth2/default or Entra's /<tenant>/v2.0.
func NewProvider(t *testing.T, alg, path string) *Provider {
	p := &Provider{ClientID: "client-" + random(6), ClientSecret: "secret-" + random(24), Alg: alg,
		codes: map[string]grant{}, refreshes: map[string]Claims{}, who: Claims{"sub": "00u-sam", "email": "sam@acme.test", "name": "Sam"}}
	var err error
	if p.rsaKey, err = rsa.GenerateKey(rand.Reader, 2048); err != nil {
		panic(err)
	}
	if p.ecKey, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader); err != nil {
		panic(err)
	}
	p.kid = random(8)
	mux := http.NewServeMux()
	mux.HandleFunc(path+"/.well-known/openid-configuration", p.serveDiscovery)
	mux.HandleFunc(path+"/keys", p.serveKeys)
	mux.HandleFunc(path+"/authorize", p.serveAuthorize)
	mux.HandleFunc(path+"/token", p.serveToken)
	p.Server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if p.Down.Load() {
			http.Error(w, "down", http.StatusServiceUnavailable)
			return
		}
		mux.ServeHTTP(w, r)
	}))
	t.Cleanup(p.Server.Close)
	p.Issuer = p.Server.URL + path
	return p
}

// HTTP is a client that trusts the fake's certificate (every httptest TLS server's).
func (p *Provider) HTTP() *http.Client { return p.Server.Client() }

// SignInAs makes the next sign-ins name this person: sub and any other claims.
func (p *Provider) SignInAs(c Claims) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.who = c
}

// Mutate changes each ID token's claims before it is signed, as a broken or hostile
// provider would; nil stops.
func (p *Provider) Mutate(f func(Claims)) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.mutate = f
}

// Deny makes authorize send the browser back with this error ("" stops).
func (p *Provider) Deny(code string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.deny = code
}

// ChangeDiscovery changes the discovery document the fake serves.
func (p *Provider) ChangeDiscovery(f func(map[string]any)) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.discovery = f
}

// Issued is every token the fake gave.
func (p *Provider) Issued() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]string{}, p.issued...)
}

// Authorized is the query of each authorize request, oldest first.
func (p *Provider) Authorized() []url.Values {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]url.Values{}, p.authorized...)
}

func (p *Provider) serveDiscovery(w http.ResponseWriter, r *http.Request) {
	doc := map[string]any{
		"issuer":                                p.Issuer,
		"authorization_endpoint":                p.Issuer + "/authorize",
		"token_endpoint":                        p.Issuer + "/token",
		"jwks_uri":                              p.Issuer + "/keys",
		"response_types_supported":              []string{"code", "id_token"},
		"grant_types_supported":                 []string{"authorization_code", "refresh_token"},
		"code_challenge_methods_supported":      []string{"S256"},
		"token_endpoint_auth_methods_supported": []string{"client_secret_basic", "client_secret_post"},
		"id_token_signing_alg_values_supported": []string{p.Alg},
		"scopes_supported":                      []string{"openid", "email", "profile", "offline_access"},
	}
	p.mu.Lock()
	if p.discovery != nil {
		p.discovery(doc)
	}
	p.mu.Unlock()
	json.NewEncoder(w).Encode(doc)
}

func (p *Provider) serveKeys(w http.ResponseWriter, r *http.Request) {
	keys := []map[string]string{
		{"kty": "RSA", "kid": p.kid + "-rsa", "use": "sig", "alg": "RS256", "n": b64(p.rsaKey.N.Bytes()), "e": b64(big.NewInt(int64(p.rsaKey.E)).Bytes())},
		{"kty": "EC", "kid": p.kid + "-ec", "use": "sig", "alg": "ES256", "crv": "P-256",
			"x": b64(p.ecKey.X.FillBytes(make([]byte, 32))), "y": b64(p.ecKey.Y.FillBytes(make([]byte, 32)))},
	}
	json.NewEncoder(w).Encode(map[string]any{"keys": keys})
}

// serveAuthorize signs in p.who at once and sends the browser back with a code.
func (p *Provider) serveAuthorize(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	p.mu.Lock()
	p.authorized = append(p.authorized, q)
	deny, who := p.deny, Claims{}
	for k, v := range p.who {
		who[k] = v
	}
	p.mu.Unlock()
	back, err := url.Parse(q.Get("redirect_uri"))
	if err != nil || q.Get("client_id") != p.ClientID || q.Get("response_type") != "code" {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	answer := url.Values{"state": {q.Get("state")}}
	switch {
	case deny != "":
		answer.Set("error", deny)
	case q.Get("code_challenge_method") != "S256" || q.Get("code_challenge") == "":
		answer.Set("error", "invalid_request")
	default:
		code := random(16)
		p.mu.Lock()
		p.codes[code] = grant{claims: who, nonce: q.Get("nonce"), challenge: q.Get("code_challenge"), redirectURI: back.String()}
		p.mu.Unlock()
		answer.Set("code", code)
	}
	back.RawQuery = answer.Encode()
	http.Redirect(w, r, back.String(), http.StatusFound)
}

// serveToken is the token call: a code with its PKCE verifier, or a refresh token, from a
// client that proves its secret.
func (p *Provider) serveToken(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || r.ParseForm() != nil {
		tokenError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	id, secret, ok := r.BasicAuth()
	if ok {
		id, _ = url.QueryUnescape(id)
		secret, _ = url.QueryUnescape(secret)
	} else {
		id, secret = r.PostForm.Get("client_id"), r.PostForm.Get("client_secret")
	}
	if id != p.ClientID || secret != p.ClientSecret {
		tokenError(w, http.StatusUnauthorized, "invalid_client")
		return
	}
	var claims Claims
	nonce := ""
	switch r.PostForm.Get("grant_type") {
	case "authorization_code":
		p.mu.Lock()
		g, found := p.codes[r.PostForm.Get("code")]
		delete(p.codes, r.PostForm.Get("code"))
		p.mu.Unlock()
		sum := sha256.Sum256([]byte(r.PostForm.Get("code_verifier")))
		if !found || g.redirectURI != r.PostForm.Get("redirect_uri") || b64(sum[:]) != g.challenge {
			tokenError(w, http.StatusBadRequest, "invalid_grant")
			return
		}
		claims, nonce = g.claims, g.nonce
	case "refresh_token":
		p.mu.Lock()
		c, found := p.refreshes[r.PostForm.Get("refresh_token")]
		p.mu.Unlock()
		if !found || p.InvalidGrant.Load() {
			tokenError(w, http.StatusBadRequest, "invalid_grant")
			return
		}
		claims = c
	default:
		tokenError(w, http.StatusBadRequest, "unsupported_grant_type")
		return
	}
	now := time.Now()
	full := Claims{"iss": p.Issuer, "aud": p.ClientID, "iat": now.Unix(), "exp": now.Add(time.Hour).Unix()}
	if nonce != "" {
		full["nonce"] = nonce
	}
	for k, v := range claims {
		full[k] = v
	}
	p.mu.Lock()
	if p.mutate != nil {
		p.mutate(full)
	}
	p.mu.Unlock()
	idToken := p.sign(full)
	access, refresh := "at-"+random(24), "rt-"+random(24)
	p.mu.Lock()
	p.refreshes[refresh] = claims
	p.issued = append(p.issued, idToken, access, refresh)
	p.mu.Unlock()
	p.Tokens.Add(1)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"token_type": "Bearer", "expires_in": 3600, "id_token": idToken,
		"access_token": access, "refresh_token": refresh})
}

// MintID signs claims as the provider's ID token, with iss, aud, iat and exp filled in
// when absent: a token the test hands somewhere it was not made for.
func (p *Provider) MintID(c Claims) string {
	now := time.Now()
	full := Claims{"iss": p.Issuer, "aud": p.ClientID, "iat": now.Unix(), "exp": now.Add(time.Hour).Unix()}
	for k, v := range c {
		full[k] = v
	}
	return p.sign(full)
}

func (p *Provider) sign(c Claims) string {
	if p.Forge.Load() {
		other, _ := rsa.GenerateKey(rand.Reader, 2048)
		return MintWith(other, p.kid+"-rsa", "RS256", c)
	}
	if p.Alg != "ES256" {
		return MintWith(p.rsaKey, p.kid+"-rsa", "RS256", c)
	}
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": p.kid + "-ec", "typ": "JWT"})
	body, _ := json.Marshal(c)
	signing := b64(header) + "." + b64(body)
	digest := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, p.ecKey, digest[:])
	if err != nil {
		panic(err)
	}
	signature := append(r.FillBytes(make([]byte, 32)), s.FillBytes(make([]byte, 32))...)
	return signing + "." + b64(signature)
}

func tokenError(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": code})
}

func random(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return strings.TrimRight(base64.RawURLEncoding.EncodeToString(b), "=")
}
