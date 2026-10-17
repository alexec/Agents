package mcpcatalog

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Signing in to a person's MCP server as the MCP authorization spec has it, the app as the
// OAuth client (MCPOAuth, #306): protected-resource metadata (RFC 9728), the authorization
// server's (RFC 8414 or OpenID discovery), dynamic registration (RFC 7591) or the person's
// own client, then the authorization code with PKCE S256 and the resource (RFC 8707),
// exchanged for tokens and refreshed before an agent starts. Only outcomes are logged, by
// the caller, in words: never a URL, a code, a client secret or a token.

// OAuthFailure is a sign-in that did not go through.
type OAuthFailure struct {
	Kind string // noMetadata, resourceMismatch, noPKCE, needsClient, refused, invalidGrant, malformed, unreachable
	Why  string // a refusal's own words, or the issuer for needsClient
}

func (f *OAuthFailure) Error() string { return f.Kind }

// Sentence is the failure for the person; never a URL or a token.
func (f *OAuthFailure) Sentence() string {
	switch f.Kind {
	case "noMetadata":
		return "This server doesn't say how to sign in to it."
	case "resourceMismatch":
		return "This server's sign-in describes a different server, so the app won't use it."
	case "noPKCE":
		return "This server's sign-in doesn't offer PKCE, which the app needs to sign in safely."
	case "needsClient":
		return "This server's sign-in doesn't let apps register themselves. Give it a client ID you registered with it."
	case "refused":
		if f.Why == "" {
			return "The sign-in was refused."
		}
		return "The sign-in was refused: " + f.Why
	case "invalidGrant":
		return "The sign-in has ended. Sign in again."
	case "malformed":
		return "The sign-in answered with something the app couldn't read."
	}
	return "The sign-in couldn't be reached."
}

// LogWord is the failure in one word, for the log.
func (f *OAuthFailure) LogWord() string {
	switch f.Kind {
	case "noMetadata":
		return "no metadata"
	case "resourceMismatch":
		return "resource mismatch"
	case "noPKCE":
		return "no PKCE"
	case "needsClient":
		return "needs a client"
	case "invalidGrant":
		return "invalid grant"
	}
	return f.Kind
}

func oauthFailure(kind string) *OAuthFailure { return &OAuthFailure{Kind: kind} }

// AuthorizationServer is RFC 8414's document, as much as signing in needs.
type AuthorizationServer struct {
	Issuer                string   `json:"issuer"`
	AuthorizationEndpoint string   `json:"authorizationEndpoint"`
	TokenEndpoint         string   `json:"tokenEndpoint"`
	RegistrationEndpoint  *string  `json:"registrationEndpoint,omitempty"`
	RevocationEndpoint    *string  `json:"revocationEndpoint,omitempty"`
	CodeChallengeMethods  []string `json:"codeChallengeMethods,omitempty"`
	Scopes                []string `json:"scopes,omitempty"`
}

// Client is the app as a client of the authorization server: registered for one sign-in,
// or given by the person.
type Client struct {
	ID     string  `json:"id"`
	Secret *string `json:"secret,omitempty"`
	// AuthMethod client_secret_basic sends the secret as Basic; anything else, in the form.
	AuthMethod *string `json:"authMethod,omitempty"`
}

// Tokens is what a token endpoint answers.
type Tokens struct {
	Access, Refresh string
	ExpiresIn       *int
}

// Plan is where a sign-in goes, found before the browser opens.
type Plan struct {
	Resource string
	Server   AuthorizationServer
	Scopes   []string
}

// OAuth is the HTTP the sign-in speaks.
type OAuth struct{ Client *http.Client }

// Canonical is the server's address as a resource: scheme and host in lower case, no
// fragment, no default port, the path as written.
func Canonical(server string) (string, bool) {
	u, err := url.Parse(strings.TrimSpace(server))
	if err != nil || u.Host == "" {
		return "", false
	}
	scheme := strings.ToLower(u.Scheme)
	if scheme != "http" && scheme != "https" {
		return "", false
	}
	u.Scheme = scheme
	host, port := strings.ToLower(u.Hostname()), u.Port()
	if scheme == "https" && port == "443" || scheme == "http" && port == "80" {
		port = ""
	}
	u.Host = host
	if port != "" {
		u.Host = host + ":" + port
	}
	u.Fragment = ""
	return u.String(), true
}

func origin(u *url.URL) string { return u.Scheme + "://" + u.Host }

// resourceMetadataURLs is where RFC 9728's document may be, in order.
func resourceMetadataURLs(server string, named string) []string {
	if named != "" {
		return []string{named}
	}
	u, err := url.Parse(server)
	if err != nil || u.Host == "" {
		return nil
	}
	var out []string
	if p := u.Path; p != "" && p != "/" {
		out = append(out, origin(u)+"/.well-known/oauth-protected-resource"+p)
	}
	return append(out, origin(u)+"/.well-known/oauth-protected-resource")
}

// authorizationServerMetadataURLs is where an issuer's metadata may be, in the MCP spec's
// order.
func authorizationServerMetadataURLs(issuer string) []string {
	u, err := url.Parse(issuer)
	if err != nil || u.Host == "" {
		return nil
	}
	o, p := origin(u), strings.TrimRight(u.Path, "/")
	if p == "" {
		return []string{o + "/.well-known/oauth-authorization-server", o + "/.well-known/openid-configuration"}
	}
	return []string{o + "/.well-known/oauth-authorization-server" + p, o + "/.well-known/openid-configuration" + p,
		o + p + "/.well-known/openid-configuration"}
}

var resourceMetadataParam = regexp.MustCompile(`resource_metadata\s*=\s*("[^"]*"|[^,\s]+)`)

// ResourceMetadata is resource_metadata from a WWW-Authenticate header, quoted or not.
func ResourceMetadata(header string) string {
	m := resourceMetadataParam.FindStringSubmatch(header)
	if m == nil {
		return ""
	}
	return strings.Trim(m[1], `"`)
}

// Discover finds where to sign in. A server with no protected-resource metadata is taken to
// be its own authorization server.
func (o OAuth) Discover(ctx context.Context, server, resourceMetadata string) (Plan, error) {
	resource, ok := Canonical(server)
	if !ok {
		return Plan{}, oauthFailure("noMetadata")
	}
	var protected map[string]any
	for _, u := range resourceMetadataURLs(server, resourceMetadata) {
		if j, err := o.getJSON(ctx, u); err != nil {
			return Plan{}, err
		} else if j != nil {
			protected = j
			break
		}
	}
	strs := func(v any) []string {
		var out []string
		if list, ok := v.([]any); ok {
			for _, x := range list {
				if s, ok := x.(string); ok {
					out = append(out, s)
				}
			}
		}
		return out
	}
	named, _ := protected["resource"].(string)
	if named != "" {
		mine, _ := url.Parse(resource)
		theirsText, _ := Canonical(named)
		theirs, err := url.Parse(theirsText)
		if err != nil || theirsText == "" || mine.Scheme != theirs.Scheme || mine.Host != theirs.Host ||
			!strings.HasPrefix(mine.Path, strings.TrimSuffix(theirs.Path, "/")) {
			return Plan{}, oauthFailure("resourceMismatch")
		}
	}
	issuers := strs(protected["authorization_servers"])
	if len(issuers) == 0 {
		u, _ := url.Parse(resource)
		issuers = []string{origin(u)}
	}
	for _, issuer := range issuers {
		for _, u := range authorizationServerMetadataURLs(issuer) {
			j, err := o.getJSON(ctx, u)
			if err != nil {
				return Plan{}, err
			}
			authorize, _ := j["authorization_endpoint"].(string)
			token, _ := j["token_endpoint"].(string)
			if j == nil || authorize == "" || token == "" {
				continue
			}
			found := AuthorizationServer{Issuer: issuer, AuthorizationEndpoint: authorize, TokenEndpoint: token,
				CodeChallengeMethods: strs(j["code_challenge_methods_supported"]), Scopes: strs(j["scopes_supported"])}
			if s, ok := j["issuer"].(string); ok {
				found.Issuer = s
			}
			if s, ok := j["registration_endpoint"].(string); ok {
				found.RegistrationEndpoint = &s
			}
			if s, ok := j["revocation_endpoint"].(string); ok {
				found.RevocationEndpoint = &s
			}
			s256 := false
			for _, m := range found.CodeChallengeMethods {
				s256 = s256 || m == "S256"
			}
			if !s256 {
				return Plan{}, oauthFailure("noPKCE")
			}
			scopes := strs(protected["scopes_supported"])
			if len(scopes) > 0 && contains(found.Scopes, "offline_access") && !contains(scopes, "offline_access") {
				scopes = append(scopes, "offline_access")
			}
			plan := Plan{Resource: resource, Server: found, Scopes: scopes}
			if named != "" {
				if c, ok := Canonical(named); ok {
					plan.Resource = c
				}
			}
			return plan, nil
		}
	}
	return Plan{}, oauthFailure("noMetadata")
}

func contains(xs []string, x string) bool {
	for _, y := range xs {
		if y == x {
			return true
		}
	}
	return false
}

// RandomToken is 32 random bytes, base64url: 43 characters.
func RandomToken() string {
	b := make([]byte, 32)
	rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

// Challenge is S256: base64url of the verifier's SHA-256.
func Challenge(verifier string) string {
	sum := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

// Register is RFC 7591, as a public client of the loopback redirect.
func (o OAuth) Register(ctx context.Context, endpoint, redirect string) (Client, error) {
	body, _ := json.Marshal(map[string]any{"client_name": "Agents", "redirect_uris": []string{redirect},
		"grant_types": []string{"authorization_code", "refresh_token"}, "response_types": []string{"code"},
		"token_endpoint_auth_method": "none"})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return Client{}, oauthFailure("malformed")
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	data, status, _, err := o.send(req)
	if err != nil {
		return Client{}, err
	}
	if status < 200 || status >= 300 {
		return Client{}, refusal(data)
	}
	var answer struct {
		ID         string  `json:"client_id"`
		Secret     *string `json:"client_secret"`
		AuthMethod *string `json:"token_endpoint_auth_method"`
	}
	if json.Unmarshal(data, &answer) != nil || answer.ID == "" {
		return Client{}, oauthFailure("malformed")
	}
	return Client{ID: answer.ID, Secret: answer.Secret, AuthMethod: answer.AuthMethod}, nil
}

// AuthorizationURL is the page the person signs in on.
func AuthorizationURL(p Plan, c Client, redirect, state, challenge string) (string, bool) {
	u, err := url.Parse(p.Server.AuthorizationEndpoint)
	if err != nil {
		return "", false
	}
	q := u.Query()
	q.Set("response_type", "code")
	q.Set("client_id", c.ID)
	q.Set("redirect_uri", redirect)
	q.Set("code_challenge", challenge)
	q.Set("code_challenge_method", "S256")
	q.Set("state", state)
	q.Set("resource", p.Resource)
	if len(p.Scopes) > 0 {
		q.Set("scope", strings.Join(p.Scopes, " "))
	}
	u.RawQuery = strings.ReplaceAll(q.Encode(), "+", "%20")
	return u.String(), true
}

// Exchange is the code for tokens, with PKCE's verifier and the resource.
func (o OAuth) Exchange(ctx context.Context, code, verifier, redirect string, c Client, p Plan) (Tokens, error) {
	return o.token(ctx, p.Server.TokenEndpoint, c, [][2]string{{"grant_type", "authorization_code"}, {"code", code},
		{"redirect_uri", redirect}, {"code_verifier", verifier}, {"resource", p.Resource}})
}

// Refresh is a refresh token for fresh tokens; invalidGrant when it is no longer taken.
func (o OAuth) Refresh(ctx context.Context, refresh, tokenEndpoint string, c Client, resource string) (Tokens, error) {
	return o.token(ctx, tokenEndpoint, c, [][2]string{{"grant_type", "refresh_token"}, {"refresh_token", refresh},
		{"resource", resource}})
}

// Revoke is best effort: a sign-out forgets the grant whatever it answers.
func (o OAuth) Revoke(ctx context.Context, token, endpoint string, c Client) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if req, err := formRequest(ctx, endpoint, c, [][2]string{{"token", token}}); err == nil {
		o.send(req)
	}
}

func (o OAuth) token(ctx context.Context, endpoint string, c Client, form [][2]string) (Tokens, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	req, err := formRequest(ctx, endpoint, c, form)
	if err != nil {
		return Tokens{}, oauthFailure("malformed")
	}
	data, status, kind, err := o.send(req)
	if err != nil {
		return Tokens{}, err
	}
	if status < 200 || status >= 300 {
		return Tokens{}, refusal(data)
	}
	j := map[string]any{}
	if !strings.Contains(strings.ToLower(kind), "json") || json.Unmarshal(data, &j) != nil {
		j = formJSON(data)
	}
	// GitHub answers an error with a 200.
	if _, ok := j["error"].(string); ok {
		return Tokens{}, refusal(data)
	}
	access, _ := j["access_token"].(string)
	if access == "" {
		return Tokens{}, oauthFailure("malformed")
	}
	t := Tokens{Access: access}
	t.Refresh, _ = j["refresh_token"].(string)
	switch e := j["expires_in"].(type) {
	case float64:
		n := int(e)
		t.ExpiresIn = &n
	case string:
		if n, err := strconv.Atoi(e); err == nil {
			t.ExpiresIn = &n
		}
	}
	return t, nil
}

func formRequest(ctx context.Context, endpoint string, c Client, form [][2]string) (*http.Request, error) {
	fields := url.Values{}
	order := []string{}
	add := func(k, v string) { fields.Add(k, v); order = append(order, k) }
	for _, f := range form {
		add(f[0], f[1])
	}
	basic := ""
	if c.Secret != nil && c.AuthMethod != nil && *c.AuthMethod == "client_secret_basic" {
		pair := url.QueryEscape(c.ID) + ":" + url.QueryEscape(*c.Secret)
		basic = "Basic " + base64.StdEncoding.EncodeToString([]byte(pair))
	} else {
		add("client_id", c.ID)
		if c.Secret != nil {
			add("client_secret", *c.Secret)
		}
	}
	var parts []string
	for _, k := range order {
		parts = append(parts, url.QueryEscape(k)+"="+url.QueryEscape(fields.Get(k)))
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(strings.Join(parts, "&")))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	if basic != "" {
		req.Header.Set("Authorization", basic)
	}
	return req, nil
}

// formJSON is a=1&b=2 as JSON, for a token endpoint that answers in a form.
func formJSON(data []byte) map[string]any {
	out := map[string]any{}
	q, err := url.ParseQuery(string(data))
	if err != nil {
		return out
	}
	for k, v := range q {
		if len(v) > 0 {
			out[k] = v[0]
		}
	}
	return out
}

func refusal(data []byte) error {
	j := map[string]any{}
	if json.Unmarshal(data, &j) != nil {
		j = formJSON(data)
	}
	if j["error"] == "invalid_grant" {
		return oauthFailure("invalidGrant")
	}
	words, _ := j["error_description"].(string)
	if words == "" {
		words, _ = j["error"].(string)
	}
	if len(words) > 200 {
		words = words[:200]
	}
	return &OAuthFailure{Kind: "refused", Why: words}
}

func (o OAuth) getJSON(ctx context.Context, u string) (map[string]any, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, nil
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("MCP-Protocol-Version", "2025-06-18")
	data, status, _, err := o.send(req)
	if err != nil {
		return nil, err
	}
	j := map[string]any{}
	if status < 200 || status >= 300 || json.Unmarshal(data, &j) != nil {
		return nil, nil
	}
	return j, nil
}

func (o OAuth) send(req *http.Request) ([]byte, int, string, error) {
	client := o.Client
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return nil, 0, "", err
		}
		return nil, 0, "", oauthFailure("unreachable")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, 0, "", oauthFailure("unreachable")
	}
	return data, resp.StatusCode, resp.Header.Get("Content-Type"), nil
}
