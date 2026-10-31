package connections

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Linear is the second provider (#1343).
const Linear = "linear"

// The Agents OAuth app on Linear (#1343, made by Alex 2026-10-19). A public client: the
// authorization code with PKCE needs no client secret, at sign-in or at refresh, so there is
// none. The client ID is public.
const (
	LinearClientID = "dd741b1ff5ea16fcec75b61d86a19b6f"
	// HandBackURL is the static page that holds nothing (#1335, S1 Q1c option 4): it sends the
	// code and the state back to the client that opened the browser. deploy/site/oauth. On
	// oauth.agentloops.dev, not the apex, which is the promotional site (#3042).
	HandBackURL = "https://oauth.agentloops.dev/oauth/callback"
	// LinearScopes: read and write issues, folders and cycles; comment as the person.
	LinearScopes = "read,write"
)

// CodeFlow is the authorization code grant with PKCE (RFC 7636) for a public client, and its
// refresh. The host makes the verifier and keeps it; a client is given only the address to
// open, and gives back the code. So a code that someone else catches is of no use to them.
type CodeFlow struct {
	ClientID    string
	RedirectURI string
	Scopes      string
	// Authorize is the provider's page where the person approves; Token is where a code or a
	// refresh token is spent; API is the provider's GraphQL endpoint, for the account. A test
	// gives a fake of each.
	Authorize, Token, API string
	// Name is the provider in words, for errors: "Linear".
	Name string
	HTTP *http.Client
	Now  func() time.Time
}

// NewLinearFlow is the flow for the Agents app on linear.app.
func NewLinearFlow() *CodeFlow {
	return &CodeFlow{ClientID: LinearClientID, RedirectURI: HandBackURL, Scopes: LinearScopes,
		Authorize: "https://linear.app/oauth/authorize", Token: "https://api.linear.app/oauth/token",
		API: "https://api.linear.app/graphql", Name: "Linear", HTTP: &http.Client{Timeout: 30 * time.Second}}
}

// PKCE is one sign-in's secrets. Verifier stays on the host. State goes out in the address
// and comes back with the code; it is checked before the code is spent.
type PKCE struct {
	Verifier, Challenge, State string
}

// NewPKCE makes a verifier (32 random bytes), its S256 challenge, and a state. For a sign-in
// from the web page, origin is the page's origin: the state carries it after a dot, so the
// hand-back page sends the code to that origin only (by postMessage). With no origin, the
// hand-back page sends it to agents://oauth/callback, for the Mac and the Remote.
func NewPKCE(origin string) (PKCE, error) {
	v := make([]byte, 32)
	n := make([]byte, 16)
	if _, err := rand.Read(v); err != nil {
		return PKCE{}, err
	}
	if _, err := rand.Read(n); err != nil {
		return PKCE{}, err
	}
	p := PKCE{Verifier: base64.RawURLEncoding.EncodeToString(v), State: hex.EncodeToString(n)}
	sum := sha256.Sum256([]byte(p.Verifier))
	p.Challenge = base64.RawURLEncoding.EncodeToString(sum[:])
	if origin != "" {
		o, err := CleanOrigin(origin)
		if err != nil {
			return PKCE{}, err
		}
		p.State += "." + base64.RawURLEncoding.EncodeToString([]byte(o))
	}
	return p, nil
}

// CleanOrigin is a web page's origin, scheme://host[:port], or an error when it is not one.
func CleanOrigin(origin string) (string, error) {
	u, err := url.Parse(origin)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.User != nil ||
		(u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("the page's origin is not an http or https origin")
	}
	return u.Scheme + "://" + u.Host, nil
}

// AuthorizeURL is the address the person opens to approve.
func (f *CodeFlow) AuthorizeURL(p PKCE) string {
	q := url.Values{"client_id": {f.ClientID}, "redirect_uri": {f.RedirectURI}, "response_type": {"code"},
		"scope": {f.Scopes}, "state": {p.State}, "code_challenge": {p.Challenge},
		"code_challenge_method": {"S256"}, "prompt": {"consent"}}
	return f.Authorize + "?" + q.Encode()
}

func (f *CodeFlow) now() time.Time {
	if f.Now != nil {
		return f.Now()
	}
	return time.Now()
}

// post sends form to the token endpoint and reads the answer. A failure says what failed,
// never the form (which holds the code, the verifier or the refresh token).
func (f *CodeFlow) post(ctx context.Context, form url.Values) (oauthAnswer, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, f.Token, strings.NewReader(form.Encode()))
	if err != nil {
		return oauthAnswer{}, fmt.Errorf("the request to %s could not be made", f.Name)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	res, err := f.HTTP.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return oauthAnswer{}, ctx.Err()
		}
		return oauthAnswer{}, fmt.Errorf("%s could not be reached", f.Name)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	var a oauthAnswer
	if json.Unmarshal(b, &a) != nil {
		return oauthAnswer{}, fmt.Errorf("%s answered %d with no JSON", f.Name, res.StatusCode)
	}
	if a.Error == "" && res.StatusCode != http.StatusOK {
		return oauthAnswer{}, fmt.Errorf("%s answered %d", f.Name, res.StatusCode)
	}
	return a, nil
}

// Exchange spends the code, with the verifier, for a pair of tokens.
func (f *CodeFlow) Exchange(ctx context.Context, code, verifier string) (Token, error) {
	a, err := f.post(ctx, url.Values{"grant_type": {"authorization_code"}, "code": {code},
		"redirect_uri": {f.RedirectURI}, "client_id": {f.ClientID}, "code_verifier": {verifier}})
	if err != nil {
		return Token{}, err
	}
	if a.Error != "" {
		return Token{}, &Failure{Name: f.Name, Code: a.Error, Words: a.ErrorDescription}
	}
	return f.token(a)
}

// Refresh spends the refresh token for a new pair: Linear's refresh tokens rotate.
func (f *CodeFlow) Refresh(ctx context.Context, refresh string) (Token, error) {
	a, err := f.post(ctx, url.Values{"grant_type": {"refresh_token"}, "refresh_token": {refresh},
		"client_id": {f.ClientID}})
	if err != nil {
		return Token{}, err
	}
	switch a.Error {
	case "":
		return f.token(a)
	case "invalid_grant", "unauthorized_client", "invalid_client":
		return Token{}, ErrRefused
	}
	return Token{}, &Failure{Name: f.Name, Code: a.Error, Words: a.ErrorDescription}
}

func (f *CodeFlow) token(a oauthAnswer) (Token, error) {
	if a.AccessToken == "" {
		return Token{}, fmt.Errorf("%s gave no token", f.Name)
	}
	t := Token{Access: a.AccessToken, Refresh: a.RefreshToken}
	if a.ExpiresIn > 0 {
		t.AccessExpiresAt = f.now().Add(time.Duration(a.ExpiresIn) * time.Second)
	}
	return t, nil
}

// Account is who the token is for, and the workspace it reaches: Linear's viewer and
// organization.
func (f *CodeFlow) Account(ctx context.Context, access string) (login, workspace string, err error) {
	body := `{"query":"{ viewer { name email } organization { name } }"}`
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, f.API, strings.NewReader(body))
	if err != nil {
		return "", "", fmt.Errorf("the request to %s could not be made", f.Name)
	}
	req.Header.Set("Authorization", "Bearer "+access)
	req.Header.Set("Content-Type", "application/json")
	res, err := f.HTTP.Do(req)
	if err != nil {
		return "", "", fmt.Errorf("%s could not be reached", f.Name)
	}
	defer res.Body.Close()
	var a struct {
		Data struct {
			Viewer struct {
				Name  string `json:"name"`
				Email string `json:"email"`
			} `json:"viewer"`
			Organization struct {
				Name string `json:"name"`
			} `json:"organization"`
		} `json:"data"`
	}
	if res.StatusCode != http.StatusOK || json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&a) != nil {
		return "", "", fmt.Errorf("%s answered %d for the account", f.Name, res.StatusCode)
	}
	login = a.Data.Viewer.Name
	if login == "" {
		login = a.Data.Viewer.Email
	}
	if login == "" {
		return "", "", fmt.Errorf("%s gave no account", f.Name)
	}
	return login, a.Data.Organization.Name, nil
}
