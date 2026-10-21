package signin

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"time"
)

// GitHubAPI checks a GitHub user access token (R3): GET /user once, and the membership of
// an allowed organisation. The token is used for those calls and then forgotten; GitHub
// gives no ID token, so it cannot carry the control plane's nonce.
type GitHubAPI struct {
	// Base is https://api.github.com, or a fake's address in tests.
	Base string
	HTTP *http.Client
}

// GitHubUser is who a token names: the numeric id, which never changes, and the login,
// which can.
type GitHubUser struct {
	ID    string
	Login string
	Name  string
}

func (g *GitHubAPI) base() string {
	if g.Base != "" {
		return g.Base
	}
	return "https://api.github.com"
}

func (g *GitHubAPI) client() *http.Client {
	if g.HTTP != nil {
		return g.HTTP
	}
	return &http.Client{Timeout: 10 * time.Second}
}

func (g *GitHubAPI) get(ctx context.Context, token, path string, v any) (int, error) {
	unavailable := &Unavailable{"GitHub could not be reached, so sign-in with GitHub is not available now. Try again later."}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, g.base()+path, nil)
	if err != nil {
		return 0, unavailable
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	resp, err := g.client().Do(req)
	if err != nil {
		return 0, unavailable
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusOK:
		if json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(v) != nil {
			return resp.StatusCode, unavailable
		}
		return resp.StatusCode, nil
	case resp.StatusCode >= 500 || resp.StatusCode == http.StatusTooManyRequests:
		return resp.StatusCode, unavailable
	}
	return resp.StatusCode, nil
}

// User is GET /user with the token.
func (g *GitHubAPI) User(ctx context.Context, token string) (*GitHubUser, error) {
	if token == "" {
		return nil, refuse("Sign in with GitHub first.")
	}
	var u struct {
		ID    json.Number `json:"id"`
		Login string      `json:"login"`
		Name  string      `json:"name"`
		Type  string      `json:"type"`
	}
	status, err := g.get(ctx, token, "/user", &u)
	if err != nil {
		return nil, err
	}
	if status == http.StatusUnauthorized || status == http.StatusForbidden {
		return nil, refuse("GitHub did not accept that sign-in. It may have expired: sign in again.")
	}
	if status != http.StatusOK {
		return nil, &Unavailable{fmt.Sprintf("GitHub answered %d, so sign-in with GitHub is not available now.", status)}
	}
	id, err := strconv.ParseInt(u.ID.String(), 10, 64)
	if err != nil || id <= 0 || u.Login == "" {
		return nil, &Unavailable{"GitHub's answer named nobody, so sign-in with GitHub is not available now."}
	}
	if u.Type != "" && u.Type != "User" {
		return nil, refuse("That GitHub account is not a person's.")
	}
	return &GitHubUser{ID: strconv.FormatInt(id, 10), Login: u.Login, Name: u.Name}, nil
}

// InOrganisation says the token's user is an active member of the organisation:
// GET /user/memberships/orgs/<org>.
func (g *GitHubAPI) InOrganisation(ctx context.Context, token, org string) (bool, error) {
	var m struct {
		State string `json:"state"`
	}
	status, err := g.get(ctx, token, "/user/memberships/orgs/"+url.PathEscape(org), &m)
	if err != nil {
		return false, err
	}
	return status == http.StatusOK && m.State == "active", nil
}
