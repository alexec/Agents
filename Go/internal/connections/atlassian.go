package connections

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Atlassian is one sign-in for Jira and Confluence (#3304, #3248): Atlassian Cloud's OAuth 2.0
// (3LO), or a token on one site (a Jira Cloud API token with the account's email, or a Jira
// Data Center personal access token).
const Atlassian = "atlassian"

// Atlassian's 3LO has no public clients: the code and every refresh are spent with the app's
// client secret, so the host keeps it. Neither is in this build: the host reads both from the
// person's secrets (~/.agents-secrets/secrets.env), as AtlassianClientIDName and
// AtlassianClientSecretName, so a build without them connects by token only. The PKCE
// challenge goes out as well.
const (
	AtlassianClientIDName     = "ATLASSIAN_CLIENT_ID"
	AtlassianClientSecretName = "ATLASSIAN_CLIENT_SECRET"
	// AtlassianScopes: read Jira's issues and users, read Confluence's pages and spaces (the
	// Docs slot, #3248), the account (read:me), and a refresh token (offline_access). The
	// Agents app on developer.atlassian.com must have each of them.
	AtlassianScopes = "read:jira-work read:jira-user read:confluence-content.all read:confluence-space.summary " +
		"search:confluence read:me offline_access"
	// AtlassianAPI is where a 3LO token is sent: api.atlassian.com/ex/jira/<cloud id>.
	AtlassianAPI = "https://api.atlassian.com"
)

// NewAtlassianFlow is the flow for the Atlassian app whose client id and secret are given.
func NewAtlassianFlow(clientID, clientSecret string) *CodeFlow {
	f := &CodeFlow{ClientID: clientID, ClientSecret: clientSecret, RedirectURI: HandBackURL, Scopes: AtlassianScopes,
		Authorize: "https://auth.atlassian.com/authorize", Token: "https://auth.atlassian.com/oauth/token",
		API: AtlassianAPI, Name: "Atlassian", JSON: true, Extra: url.Values{"audience": {"api.atlassian.com"}},
		HTTP: &http.Client{Timeout: 30 * time.Second}}
	f.Who = func(ctx context.Context, access string) (Account, error) { return atlassianAccount(ctx, f, access) }
	return f
}

// atlassianAccount is the token's account (/me) and the first site it reaches with Jira
// (/oauth/token/accessible-resources): its name, address and cloud id.
func atlassianAccount(ctx context.Context, f *CodeFlow, access string) (Account, error) {
	var me struct {
		Name  string `json:"name"`
		Email string `json:"email"`
	}
	if err := atlassianGet(ctx, f, f.API+"/me", access, &me); err != nil {
		return Account{}, err
	}
	var sites []struct {
		ID     string   `json:"id"`
		Name   string   `json:"name"`
		URL    string   `json:"url"`
		Scopes []string `json:"scopes"`
	}
	if err := atlassianGet(ctx, f, f.API+"/oauth/token/accessible-resources", access, &sites); err != nil {
		return Account{}, err
	}
	a := Account{Login: me.Name}
	if a.Login == "" {
		a.Login = me.Email
	}
	for _, s := range sites {
		if s.ID == "" {
			continue
		}
		jira := false
		for _, scope := range s.Scopes {
			jira = jira || strings.Contains(scope, "jira")
		}
		if jira || a.Resource == "" {
			a.Workspace, a.URL, a.Resource = s.Name, strings.TrimRight(s.URL, "/"), s.ID
		}
		if jira {
			break
		}
	}
	if a.Login == "" {
		return Account{}, errors.New("Atlassian gave no account")
	}
	if a.Resource == "" {
		return Account{}, errors.New("the account reaches no Atlassian site: give Agent Loops a site when Atlassian asks")
	}
	return a, nil
}

func atlassianGet(ctx context.Context, f *CodeFlow, address, access string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return fmt.Errorf("the request to %s could not be made", f.Name)
	}
	req.Header.Set("Authorization", "Bearer "+access)
	req.Header.Set("Accept", "application/json")
	res, err := f.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("%s could not be reached", f.Name)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK || json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(out) != nil {
		return fmt.Errorf("%s answered %d for the account", f.Name, res.StatusCode)
	}
	return nil
}

// JiraSite is a site's address as a person types it: https:// when it names no scheme, no
// path, no slash at the end.
func JiraSite(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", errors.New("give the Jira site, as example.atlassian.net")
	}
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.User != nil || u.RawQuery != "" {
		return "", errors.New("the Jira site is not an address, such as example.atlassian.net")
	}
	return u.Scheme + "://" + u.Host + strings.TrimRight(u.Path, "/"), nil
}

// JiraHeader is the Authorization header for a connection's token: Bearer for 3LO and a Data
// Center personal access token, Basic for a Jira Cloud API token with its email.
func JiraHeader(c Connection) string {
	if c.Access == "" {
		return ""
	}
	if c.Resource == "" && c.User != "" {
		return "Basic " + base64.StdEncoding.EncodeToString([]byte(c.User+":"+c.Access))
	}
	return "Bearer " + c.Access
}

// JiraAPI is where a connection's Jira requests go: api.atlassian.com/ex/jira/<cloud id> for
// 3LO, else the site itself.
func JiraAPI(c Connection) string {
	if c.Resource != "" {
		return AtlassianAPI + "/ex/jira/" + url.PathEscape(c.Resource)
	}
	return c.URL
}
