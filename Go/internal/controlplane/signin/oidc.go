// Package signin checks a person's sign-in with Google, Apple or GitHub (#995, spec 736
// FR-008 to FR-015). The client signs in with the app's own client id and sends what it
// got; this package checks it and says who it names. Nothing here keeps or logs a token.
package signin

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"slices"
	"strings"
	"sync"
	"time"
)

// Providers, as a sign-in's provider says them.
const (
	Google = "google"
	Apple  = "apple"
	GitHub = "github"
)

// Skew is how far the control plane's clock may be from the provider's (spec 736, edge
// cases).
const Skew = 5 * time.Minute

// Refused is a sign-in that is not good, with the reason a person reads.
type Refused struct{ Reason string }

func (r *Refused) Error() string { return r.Reason }

func refuse(format string, args ...any) error { return &Refused{fmt.Sprintf(format, args...)} }

// Unavailable is a provider that could not be reached or answered wrongly: the sign-in is
// neither good nor bad, and the person is told why (FR-015).
type Unavailable struct{ Reason string }

func (u *Unavailable) Error() string { return u.Reason }

// IsRefused says err is a sign-in that is not good.
func IsRefused(err error) bool {
	var r *Refused
	return errors.As(err, &r)
}

// IsUnavailable says err is a provider that could not be asked.
func IsUnavailable(err error) bool {
	var u *Unavailable
	return errors.As(err, &u)
}

// Nonce is what a client signs in with on one connection to one control plane (R2):
// SHA-256 of the control plane's key id and the hello's nonce, in hex. A token made for
// another control plane, or for an earlier connection, names another nonce.
func Nonce(controlKeyID string, helloNonce []byte) string {
	h := sha256.New()
	h.Write([]byte("agents-signin-v1\x00"))
	h.Write([]byte(controlKeyID))
	h.Write([]byte{0})
	h.Write(helloNonce)
	return hex.EncodeToString(h.Sum(nil))
}

// Claims are what a checked ID token says of its person.
type Claims struct {
	Subject       string
	Email         string
	EmailVerified bool
	// Google Workspace's domain, for an allowed domain (FR-006); "" for any other account.
	Domain string
	Name   string
}

// OIDC checks the ID tokens of one issuer: its signature against the issuer's JWKS, iss,
// aud, the expiry and the nonce.
type OIDC struct {
	Provider string
	// Issuers are the iss values the issuer signs with (Google has two).
	Issuers []string
	// Audiences are the app's own client ids (FR-012).
	Audiences []string
	JWKSURL   string
	HTTP      *http.Client
	Now       func() time.Time

	mu      sync.Mutex
	keys    map[string]*rsa.PublicKey
	fetched time.Time
}

// GoogleOIDC is Google's issuer, for the app's client ids.
func GoogleOIDC(audiences []string) *OIDC {
	return &OIDC{Provider: Google, Issuers: []string{"https://accounts.google.com", "accounts.google.com"},
		Audiences: audiences, JWKSURL: "https://www.googleapis.com/oauth2/v3/certs"}
}

// AppleOIDC is Apple's issuer, for the app's bundle ids and Services id.
func AppleOIDC(audiences []string) *OIDC {
	return &OIDC{Provider: Apple, Issuers: []string{"https://appleid.apple.com"}, Audiences: audiences,
		JWKSURL: "https://appleid.apple.com/auth/keys"}
}

// keysKept is how long the JWKS is kept; refetchAfter how soon an unknown key id fetches
// it again, so a provider's new key works with no restart and a stream of made-up key ids
// cannot hammer the provider.
const (
	keysKept     = time.Hour
	refetchAfter = time.Minute
)

func (o *OIDC) now() time.Time {
	if o.Now != nil {
		return o.Now()
	}
	return time.Now()
}

func (o *OIDC) client() *http.Client {
	if o.HTTP != nil {
		return o.HTTP
	}
	return &http.Client{Timeout: 10 * time.Second}
}

// Check checks an ID token against the nonce this connection gave, and says who it names.
func (o *OIDC) Check(ctx context.Context, token, nonce string) (*Claims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, refuse("That is not an ID token.")
	}
	var header struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}
	if err := decodePart(parts[0], &header); err != nil {
		return nil, refuse("That is not an ID token.")
	}
	// Only what Google and Apple sign with: never "none", never a key the token brings.
	if header.Alg != "RS256" {
		return nil, refuse("The ID token is signed with %q, not RS256.", header.Alg)
	}
	key, err := o.key(ctx, header.Kid)
	if err != nil {
		return nil, err
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, refuse("The ID token's signature is not readable.")
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if rsa.VerifyPKCS1v15(key, crypto.SHA256, digest[:], signature) != nil {
		return nil, refuse("The ID token's signature is not %s's.", o.Provider)
	}
	var claims struct {
		Iss           string          `json:"iss"`
		Sub           string          `json:"sub"`
		Aud           audience        `json:"aud"`
		Exp           json.Number     `json:"exp"`
		Iat           json.Number     `json:"iat"`
		Nonce         string          `json:"nonce"`
		Email         string          `json:"email"`
		EmailVerified json.RawMessage `json:"email_verified"`
		HD            string          `json:"hd"`
		Name          string          `json:"name"`
	}
	if err := decodePart(parts[1], &claims); err != nil {
		return nil, refuse("The ID token's claims are not readable.")
	}
	if !slices.Contains(o.Issuers, claims.Iss) {
		return nil, refuse("The ID token is not from %s.", o.Provider)
	}
	if !slices.ContainsFunc(claims.Aud, func(a string) bool { return slices.Contains(o.Audiences, a) }) {
		return nil, refuse("The ID token was made for another app.")
	}
	now := o.now()
	exp, err1 := claims.Exp.Int64()
	if err1 != nil || !now.Before(time.Unix(exp, 0).Add(Skew)) {
		return nil, refuse("The ID token has expired. If it was just made, check this machine's clock.")
	}
	if iat, err := claims.Iat.Int64(); err == nil && time.Unix(iat, 0).After(now.Add(Skew)) {
		return nil, refuse("The ID token is from the future. Check this machine's clock.")
	}
	if nonce == "" || subtle.ConstantTimeCompare([]byte(claims.Nonce), []byte(nonce)) != 1 {
		return nil, refuse("The ID token was made for another sign-in. Sign in again.")
	}
	if claims.Sub == "" {
		return nil, refuse("The ID token names nobody.")
	}
	verified := string(claims.EmailVerified) == "true" || string(claims.EmailVerified) == `"true"`
	return &Claims{Subject: claims.Sub, Email: claims.Email, EmailVerified: verified, Domain: claims.HD, Name: claims.Name}, nil
}

// audience is aud, which is one string or a list.
type audience []string

func (a *audience) UnmarshalJSON(b []byte) error {
	var one string
	if json.Unmarshal(b, &one) == nil {
		*a = audience{one}
		return nil
	}
	var many []string
	if err := json.Unmarshal(b, &many); err != nil {
		return err
	}
	*a = many
	return nil
}

func decodePart(part string, v any) error {
	b, err := base64.RawURLEncoding.DecodeString(part)
	if err != nil {
		return err
	}
	d := json.NewDecoder(strings.NewReader(string(b)))
	d.UseNumber()
	return d.Decode(v)
}

// key is the issuer's key of that id, from the JWKS kept or fetched again.
func (o *OIDC) key(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	now := o.now()
	if k, ok := o.keys[kid]; ok && now.Sub(o.fetched) < keysKept {
		return k, nil
	}
	if o.keys != nil && now.Sub(o.fetched) < refetchAfter {
		if k, ok := o.keys[kid]; ok {
			return k, nil
		}
		return nil, refuse("The ID token's signature is not %s's.", o.Provider)
	}
	keys, err := o.fetch(ctx)
	if err != nil {
		// A key kept still works while the issuer cannot be reached.
		if k, ok := o.keys[kid]; ok {
			return k, nil
		}
		return nil, err
	}
	o.keys, o.fetched = keys, now
	if k, ok := keys[kid]; ok {
		return k, nil
	}
	return nil, refuse("The ID token's signature is not %s's.", o.Provider)
}

func (o *OIDC) fetch(ctx context.Context) (map[string]*rsa.PublicKey, error) {
	unavailable := &Unavailable{fmt.Sprintf("%s's keys could not be read, so sign-in with %s is not available now. Try again later.",
		Title(o.Provider), Title(o.Provider))}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, o.JWKSURL, nil)
	if err != nil {
		return nil, unavailable
	}
	resp, err := o.client().Do(req)
	if err != nil {
		return nil, unavailable
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, unavailable
	}
	var set struct {
		Keys []struct {
			Kty string `json:"kty"`
			Kid string `json:"kid"`
			Use string `json:"use"`
			N   string `json:"n"`
			E   string `json:"e"`
		} `json:"keys"`
	}
	if json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&set) != nil {
		return nil, unavailable
	}
	keys := map[string]*rsa.PublicKey{}
	for _, k := range set.Keys {
		if k.Kty != "RSA" || (k.Use != "" && k.Use != "sig") {
			continue
		}
		n, err1 := base64.RawURLEncoding.DecodeString(k.N)
		e, err2 := base64.RawURLEncoding.DecodeString(k.E)
		if err1 != nil || err2 != nil || len(e) > 4 || len(n) < 256 {
			continue
		}
		keys[k.Kid] = &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(new(big.Int).SetBytes(e).Int64())}
	}
	if len(keys) == 0 {
		return nil, unavailable
	}
	return keys, nil
}

// Title is a provider as the screen says it.
func Title(provider string) string {
	switch provider {
	case Google:
		return "Google"
	case Apple:
		return "Apple"
	case GitHub:
		return "GitHub"
	}
	return provider
}
