package hosted

import (
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/controlplane/signin"
)

// Sign up with Apple and Google (#3386): the browser goes to the provider by the OIDC code
// flow, and comes back to /signin/callback, as from GitHub. The service trades the code for
// an ID token with its client secret, checks the token as the control plane checks one
// (signin.OIDC: the signature, iss, aud, the expiry and the sign-in's nonce), takes its
// subject and the email the provider verified (#3388), and forgets the rest. It asks for
// openid and email: no name. With the email scope Apple answers only by a form post
// (response_mode=form_post), so the callback takes a POST too.

// Endpoints are where a provider is asked; tests give a fake's.
type Endpoints struct {
	Issuer, Authorize, Token, JWKS string
}

var (
	appleAt  = Endpoints{Issuer: "https://appleid.apple.com", Authorize: "https://appleid.apple.com/auth/authorize", Token: "https://appleid.apple.com/auth/token", JWKS: "https://appleid.apple.com/auth/keys"}
	googleAt = Endpoints{Issuer: "https://accounts.google.com", Authorize: "https://accounts.google.com/o/oauth2/v2/auth", Token: "https://oauth2.googleapis.com/token", JWKS: "https://www.googleapis.com/oauth2/v3/certs"}
)

// oidcSignIn is the web sign-in with one OIDC provider.
type oidcSignIn struct {
	provider string
	clientID string
	// secret is the client secret for one token call: Google's, or a JWT for Apple's.
	secret   func() (string, error)
	at       Endpoints
	redirect string
	// pkce says the provider takes PKCE: Google does; Apple does not say it does, and
	// answers by a form post.
	pkce  bool
	check *signin.OIDC
	http  *http.Client
}

func newOIDCSignIn(provider, clientID string, secret func() (string, error), at, real Endpoints, redirect string, hc *http.Client) *oidcSignIn {
	if at == (Endpoints{}) {
		at = real
	}
	if hc == nil {
		hc = client
	}
	check := &signin.OIDC{Provider: provider, Issuers: []string{at.Issuer}, Audiences: []string{clientID}, JWKSURL: at.JWKS, HTTP: hc}
	if provider == signin.Google && at.Issuer == real.Issuer {
		// Google signs with either.
		check.Issuers = append(check.Issuers, "accounts.google.com")
	}
	return &oidcSignIn{provider: provider, clientID: clientID, secret: secret, at: at, redirect: redirect,
		pkce: provider == signin.Google, check: check, http: hc}
}

// authorize is where the browser goes to sign in, for this state, nonce and PKCE verifier.
func (o *oidcSignIn) authorize(state, nonce, verifier string) string {
	q := url.Values{"client_id": {o.clientID}, "redirect_uri": {o.redirect}, "response_type": {"code"},
		"scope": {"openid email"}, "state": {state}, "nonce": {nonce}}
	if o.pkce {
		sum := sha256.Sum256([]byte(verifier))
		q.Set("code_challenge", base64.RawURLEncoding.EncodeToString(sum[:]))
		q.Set("code_challenge_method", "S256")
	} else {
		// Apple asked for an email comes back only by a form post.
		q.Set("response_mode", "form_post")
	}
	return o.at.Authorize + "?" + q.Encode()
}

// user trades a code for the sign-in its ID token names.
func (o *oidcSignIn) user(ctx context.Context, code, nonce, verifier string) (SignIn, error) {
	secret, err := o.secret()
	if err != nil {
		return SignIn{}, err
	}
	if !o.pkce {
		verifier = ""
	}
	d := &signin.Discovery{TokenEndpoint: o.at.Token, TokenAuthMethods: []string{"client_secret_post"}}
	tokens, err := signin.Exchange(ctx, o.http, d, o.clientID, secret, code, o.redirect, verifier, signin.Title(o.provider))
	if err != nil {
		return SignIn{}, err
	}
	claims, err := o.check.Check(ctx, tokens.IDToken, nonce)
	if err != nil {
		return SignIn{}, err
	}
	user := SignIn{Provider: o.provider, Subject: claims.Subject}
	// Google says if it verified the email; Apple gives only verified ones, a private
	// relay address too (#3387).
	if claims.Email != "" && (claims.EmailVerified || o.provider == signin.Apple) {
		user.Email = strings.ToLower(claims.Email)
	}
	if !user.valid() {
		return SignIn{}, errors.New(signin.Title(o.provider) + " named a subject this service cannot keep")
	}
	return user, nil
}

// appleSecret is Sign in with Apple's client secret: a JWT signed with the team's Sign in
// with Apple key, made for each token call and good for five minutes, as APNs' provider
// token is made (controlplane/apns).
type appleSecret struct {
	team, keyID, servicesID string
	key                     *ecdsa.PrivateKey
	now                     func() time.Time
}

func (a appleSecret) make() (string, error) {
	now := a.now()
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": a.keyID})
	claims, _ := json.Marshal(map[string]any{"iss": a.team, "iat": now.Unix(), "exp": now.Add(5 * time.Minute).Unix(),
		"aud": "https://appleid.apple.com", "sub": a.servicesID})
	signing := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, a.key, digest[:])
	if err != nil {
		return "", err
	}
	// JWS's ES256 signature is r and s, 32 bytes each, not DER.
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signing + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}

// parseAppleKey reads the Sign in with Apple key: the .p8 file's text, or, for a .env file
// of one line each, the base64 between its BEGIN and END lines.
func parseAppleKey(text []byte) (*ecdsa.PrivateKey, error) {
	der := []byte(nil)
	if block, _ := pem.Decode([]byte(strings.ReplaceAll(string(text), `\n`, "\n"))); block != nil {
		der = block.Bytes
	} else if b, err := base64.StdEncoding.DecodeString(strings.Join(strings.Fields(string(text)), "")); err == nil {
		der = b
	} else {
		return nil, errors.New("it is not a .p8 key")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(der)
	if err != nil {
		return nil, errors.New("it is not a PKCS #8 private key")
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve.Params().Name != "P-256" {
		return nil, errors.New("it is not a P-256 key")
	}
	return key, nil
}
