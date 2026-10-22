package signin

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"sync"
	"time"
)

// Org providers (#1002, spec D1, D2): an organisation's own OIDC issuer, which the control
// plane signs in with as a confidential client, by the code flow with PKCE. Every org
// provider is the same kind: what it needs is read from its discovery document.

// Discovery is the part of an issuer's discovery document the code flow needs.
type Discovery struct {
	Issuer                string   `json:"issuer"`
	AuthorizationEndpoint string   `json:"authorization_endpoint"`
	TokenEndpoint         string   `json:"token_endpoint"`
	JWKSURI               string   `json:"jwks_uri"`
	ResponseTypes         []string `json:"response_types_supported"`
	CodeChallengeMethods  []string `json:"code_challenge_methods_supported"`
	TokenAuthMethods      []string `json:"token_endpoint_auth_methods_supported"`
	Algs                  []string `json:"id_token_signing_alg_values_supported"`
	Scopes                []string `json:"scopes_supported"`
}

// discoveryKept is how long a discovery document is kept before it is read again (spec
// edge cases: an issuer that changes its endpoints).
const discoveryKept = time.Hour

// ReadDiscovery reads issuer's /.well-known/openid-configuration.
func ReadDiscovery(ctx context.Context, client *http.Client, issuer, name string) (*Discovery, error) {
	unavailable := &Unavailable{fmt.Sprintf("%s cannot be reached: its discovery document could not be read. Try again later.", name)}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimSuffix(issuer, "/")+"/.well-known/openid-configuration", nil)
	if err != nil {
		return nil, unavailable
	}
	req.Header.Set("Accept", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return nil, unavailable
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, unavailable
	}
	var d Discovery
	if json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&d) != nil {
		return nil, &Refused{fmt.Sprintf("%s's discovery document is not readable.", name)}
	}
	return &d, nil
}

// Missing is what the document lacks for this control plane to sign in with it (FR-004):
// the issuer it names, https endpoints, the code flow and PKCE with S256.
func (d *Discovery) Missing(issuer string) []string {
	out := []string{}
	if strings.TrimSuffix(d.Issuer, "/") != strings.TrimSuffix(issuer, "/") {
		out = append(out, fmt.Sprintf("the issuer it names (%q) is not %q", d.Issuer, issuer))
	}
	for _, e := range []struct{ name, value string }{{"an authorization endpoint", d.AuthorizationEndpoint},
		{"a token endpoint", d.TokenEndpoint}, {"a JWKS address", d.JWKSURI}} {
		if u, err := url.Parse(e.value); e.value == "" || err != nil || u.Scheme != "https" || u.Host == "" {
			out = append(out, e.name+" on https")
		}
	}
	if len(d.ResponseTypes) > 0 && !slices.Contains(d.ResponseTypes, "code") {
		out = append(out, "the authorization code flow")
	}
	if !slices.Contains(d.CodeChallengeMethods, "S256") {
		out = append(out, "PKCE with S256")
	}
	if len(d.TokenAuthMethods) > 0 && !slices.Contains(d.TokenAuthMethods, "client_secret_basic") &&
		!slices.Contains(d.TokenAuthMethods, "client_secret_post") {
		out = append(out, "a client secret at the token endpoint")
	}
	return out
}

// Discoveries keeps each issuer's discovery document for an hour.
type Discoveries struct {
	HTTP *http.Client
	Now  func() time.Time

	mu   sync.Mutex
	kept map[string]keptDiscovery
}

type keptDiscovery struct {
	d    *Discovery
	read time.Time
}

func (c *Discoveries) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

func (c *Discoveries) client() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return &http.Client{Timeout: 10 * time.Second}
}

// Get is issuer's document: the one kept, unless again or it is an hour old.
func (c *Discoveries) Get(ctx context.Context, issuer, name string, again bool) (*Discovery, error) {
	c.mu.Lock()
	k, ok := c.kept[issuer]
	c.mu.Unlock()
	if ok && !again && c.now().Sub(k.read) < discoveryKept {
		return k.d, nil
	}
	d, err := ReadDiscovery(ctx, c.client(), issuer, name)
	if err != nil {
		if ok {
			// The one kept still works while the issuer cannot be reached.
			return k.d, nil
		}
		return nil, err
	}
	c.mu.Lock()
	if c.kept == nil {
		c.kept = map[string]keptDiscovery{}
	}
	c.kept[issuer] = keptDiscovery{d, c.now()}
	c.mu.Unlock()
	return d, nil
}

// Tokens is what the token endpoint answered. The control plane checks the ID token and
// keeps none of it.
type Tokens struct {
	IDToken      string `json:"id_token"`
	RefreshToken string `json:"refresh_token"`
}

// Exchange trades an authorization code and its PKCE verifier for tokens, as a
// confidential client: client_secret_basic, or client_secret_post when the issuer lists
// only that.
func Exchange(ctx context.Context, client *http.Client, d *Discovery, clientID, secret, code, redirectURI, verifier, name string) (*Tokens, error) {
	form := url.Values{"grant_type": {"authorization_code"}, "code": {code}, "redirect_uri": {redirectURI}, "code_verifier": {verifier}}
	post := len(d.TokenAuthMethods) > 0 && !slices.Contains(d.TokenAuthMethods, "client_secret_basic")
	if post {
		form.Set("client_id", clientID)
		form.Set("client_secret", secret)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, d.TokenEndpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, &Unavailable{fmt.Sprintf("%s cannot be reached.", name)}
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	if !post {
		// RFC 6749 §2.3.1: each part form-encoded first.
		req.Header.Set("Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(url.QueryEscape(clientID)+":"+url.QueryEscape(secret))))
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, &Unavailable{fmt.Sprintf("%s cannot be reached.", name)}
	}
	defer resp.Body.Close()
	var answer struct {
		Tokens
		Error string `json:"error"`
	}
	decodeErr := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&answer)
	switch {
	case resp.StatusCode >= 500:
		return nil, &Unavailable{fmt.Sprintf("%s cannot be reached.", name)}
	case resp.StatusCode == http.StatusUnauthorized || answer.Error == "invalid_client":
		return nil, &Refused{fmt.Sprintf("%s did not accept this control plane's client secret. An admin replaces it in Console ▸ Sign-In.", name)}
	case resp.StatusCode != http.StatusOK || decodeErr != nil || answer.IDToken == "":
		return nil, &Refused{fmt.Sprintf("%s did not finish the sign-in. Sign in again.", name)}
	}
	return &answer.Tokens, nil
}

// ErrInvalidGrant is a refresh token the provider refused: the person left, was disabled
// or had their sessions revoked (#1002, Q1 A).
var ErrInvalidGrant = errors.New("invalid_grant")

// Refresh uses a refresh token, as a confidential client, and answers the refresh token
// to keep: a new one when the provider rotates them, or the same. The access and ID tokens
// it gives are forgotten here. ErrInvalidGrant when the provider refused it; Unavailable
// when it could not be reached.
func Refresh(ctx context.Context, client *http.Client, d *Discovery, clientID, secret, refresh, name string) (string, error) {
	form := url.Values{"grant_type": {"refresh_token"}, "refresh_token": {refresh}}
	post := len(d.TokenAuthMethods) > 0 && !slices.Contains(d.TokenAuthMethods, "client_secret_basic")
	if post {
		form.Set("client_id", clientID)
		form.Set("client_secret", secret)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, d.TokenEndpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return "", &Unavailable{fmt.Sprintf("%s cannot be reached.", name)}
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	if !post {
		req.Header.Set("Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(url.QueryEscape(clientID)+":"+url.QueryEscape(secret))))
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", &Unavailable{fmt.Sprintf("%s cannot be reached.", name)}
	}
	defer resp.Body.Close()
	var answer struct {
		RefreshToken string `json:"refresh_token"`
		Error        string `json:"error"`
	}
	decodeErr := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&answer)
	switch {
	case answer.Error == "invalid_grant":
		return "", ErrInvalidGrant
	case resp.StatusCode >= 500 || resp.StatusCode == http.StatusTooManyRequests:
		return "", &Unavailable{fmt.Sprintf("%s cannot be reached.", name)}
	case resp.StatusCode != http.StatusOK || decodeErr != nil:
		// A refused client secret is the control plane's to fix, not the person's: not a
		// leaver.
		return "", &Unavailable{fmt.Sprintf("%s did not take the refresh (%d %s).", name, resp.StatusCode, answer.Error)}
	}
	if answer.RefreshToken == "" {
		return refresh, nil
	}
	return answer.RefreshToken, nil
}
