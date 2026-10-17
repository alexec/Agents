package signin

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"time"
)

// Codex is CodexFileSignIn: Codex's own sign-in file on this Mac (~/.codex/auth.json,
// 047), read for every request and renewed in place on a 401, as Codex itself would.
type Codex struct {
	File string
	// TokenEndpoint is where a refresh token is exchanged.
	TokenEndpoint string
	Client        *http.Client
	Now           func() time.Time
}

// NewCodex is the file at path, renewed at OpenAI's token endpoint.
func NewCodex(path string) *Codex {
	return &Codex{File: path, TokenEndpoint: "https://auth.openai.com/oauth/token", Client: http.DefaultClient, Now: time.Now}
}

func (c *Codex) read() (map[string]any, error) {
	b, err := os.ReadFile(c.File)
	if err != nil {
		return nil, ErrNotSignedIn
	}
	var object map[string]any
	if json.Unmarshal(b, &object) != nil || object == nil {
		return nil, ErrNotSignedIn
	}
	return object, nil
}

// Current is a ChatGPT sign-in's access token and its account id.
func (c *Codex) Current() (Token, error) {
	object, err := c.read()
	if err != nil {
		return Token{}, err
	}
	tokens, _ := object["tokens"].(map[string]any)
	access, _ := tokens["access_token"].(string)
	account, _ := tokens["account_id"].(string)
	if object["auth_mode"] != "chatgpt" || access == "" || account == "" {
		return Token{}, ErrNotSignedIn
	}
	return Token{Access: access, Headers: map[string]string{"ChatGPT-Account-Id": account}}, nil
}

// Renew after stale was refused. If the file already holds another token, the runtime on
// this Mac renewed it first: that is used, and nothing is spent.
func (c *Codex) Renew(ctx context.Context, stale Token) (Token, error) {
	object, err := c.read()
	if err != nil {
		return Token{}, err
	}
	tokens, _ := object["tokens"].(map[string]any)
	refresh, _ := tokens["refresh_token"].(string)
	access, _ := tokens["access_token"].(string)
	if refresh == "" || access == "" {
		return Token{}, ErrNotSignedIn
	}
	if access != stale.Access {
		return c.Current()
	}
	clientID, _ := claims(access)["client_id"].(string)
	body, _ := json.Marshal(map[string]string{"client_id": clientID, "grant_type": "refresh_token",
		"refresh_token": refresh, "scope": "openid profile email"})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.TokenEndpoint, bytes.NewReader(body))
	if err != nil {
		return Token{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.Client.Do(req)
	if err != nil {
		return Token{}, err
	}
	defer resp.Body.Close()
	var answer map[string]any
	if resp.StatusCode != 200 || json.NewDecoder(resp.Body).Decode(&answer) != nil {
		return Token{}, ErrRenewalRefused
	}
	newAccess, _ := answer["access_token"].(string)
	if newAccess == "" {
		return Token{}, ErrRenewalRefused
	}
	tokens["access_token"] = newAccess
	for _, k := range []string{"id_token", "refresh_token"} {
		if v, ok := answer[k].(string); ok {
			tokens[k] = v
		}
	}
	object["tokens"] = tokens
	object["last_refresh"] = stamp(c.Now())
	out, _ := json.MarshalIndent(object, "", "  ")
	tmp := c.File + ".agents-tmp"
	if err := os.WriteFile(tmp, out, 0o600); err != nil {
		return Token{}, err
	}
	if err := os.Rename(tmp, c.File); err != nil {
		return Token{}, err
	}
	return c.Current()
}

// StandIn is a sign-in file the server's Codex can start with, holding nothing secret: the
// account id and plan, tokens whose signature is `standin`, no refresh token.
func (c *Codex) StandIn() (string, error) {
	object, err := c.read()
	if err != nil {
		return "", err
	}
	tokens, _ := object["tokens"].(map[string]any)
	id, _ := tokens["id_token"].(string)
	account, _ := tokens["account_id"].(string)
	if object["auth_mode"] != "chatgpt" || id == "" || account == "" {
		return "", ErrNotSignedIn
	}
	auth, _ := claims(id)["https://api.openai.com/auth"].(map[string]any)
	kept := map[string]any{}
	for _, k := range []string{"chatgpt_account_id", "chatgpt_plan_type", "chatgpt_user_id", "user_id"} {
		if v, ok := auth[k]; ok {
			kept[k] = v
		}
	}
	now := c.Now()
	far, issued := now.Unix()+30*86_400, now.Unix()
	idClaims := map[string]any{"iss": "agents-relay-standin", "aud": "agents-relay-standin", "exp": far, "iat": issued,
		"email": "relay@agents.invalid", "https://api.openai.com/auth": kept}
	accessClaims := map[string]any{"exp": far, "iat": issued, "https://api.openai.com/auth": kept}
	standIn := map[string]any{
		"auth_mode": "chatgpt", "OPENAI_API_KEY": nil,
		"tokens": map[string]any{"id_token": unsigned(idClaims), "access_token": unsigned(accessClaims),
			"refresh_token": "agents-relay-standin", "account_id": account},
		"last_refresh": stamp(now)}
	b, err := json.Marshal(standIn) // keys sorted, as .sortedKeys
	return string(b), err
}

// ClientBearer is the access token a runtime will send as `Authorization: Bearer`:
// Codex's from its stand-in JSON, Claude's the stand-in string itself.
func ClientBearer(standIn string) string {
	var object struct {
		Tokens struct {
			AccessToken string `json:"access_token"`
		} `json:"tokens"`
	}
	if json.Unmarshal([]byte(standIn), &object) == nil && object.Tokens.AccessToken != "" {
		return object.Tokens.AccessToken
	}
	return standIn
}

func claims(jwt string) map[string]any {
	parts := strings.Split(jwt, ".")
	if len(parts) < 2 {
		return nil
	}
	b, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(parts[1], "="))
	if err != nil {
		return nil
	}
	var object map[string]any
	json.Unmarshal(b, &object)
	return object
}

func unsigned(claims map[string]any) string {
	segment := func(v any) string { b, _ := json.Marshal(v); return base64.RawURLEncoding.EncodeToString(b) }
	return segment(map[string]any{"alg": "none", "typ": "JWT"}) + "." + segment(claims) + ".standin"
}

// stamp is the shape the runtime writes last_refresh in: 2026-09-26T05:30:31.291Z.
func stamp(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000Z") }

func randomHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}
