package connections

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

// Forgejo is the sixth provider (#3752): an access token on Codeberg or any Forgejo or Gitea,
// which share the REST API v1. Forgejo has no device flow, and a token has no refresh and
// does not end unless the person deletes it.
const Forgejo = "forgejo"

// Codeberg is codeberg.org's root, the Forgejo a connection is on when no address is given.
const Codeberg = "https://codeberg.org/"

// ForgejoRoot is the address the person typed as a Forgejo's root with a trailing slash:
// https:// when it names no scheme, without /api/v1 on the end, codeberg.org when blank. http
// is taken only for this machine (a scratch Forgejo in a walk).
func ForgejoRoot(raw string) (string, error) { return forgeRoot(raw, Codeberg, "Forgejo", "/api/v1") }

// IsCodeberg is root codeberg.org's.
func IsCodeberg(root string) bool { return root == "" || root == Codeberg }

// CheckForgejoToken asks the Forgejo at root whose token this is. The token goes only in the
// Authorization header; an error never holds it.
func CheckForgejoToken(ctx context.Context, client *http.Client, root, token string) (string, error) {
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, root+"api/v1/user", nil)
	if err != nil {
		return "", errors.New("the request to Forgejo could not be made")
	}
	req.Header.Set("Authorization", "token "+token)
	req.Header.Set("Accept", "application/json")
	res, err := client.Do(req)
	if err != nil {
		return "", errors.New("Forgejo could not be reached")
	}
	defer res.Body.Close()
	if res.StatusCode == http.StatusUnauthorized {
		return "", errors.New("Forgejo did not take the token")
	}
	if res.StatusCode == http.StatusForbidden {
		// A token without the user scope's read can't say whose it is.
		return "", errors.New("the token can't read its account: give it read on user, and read and write on repository and issue")
	}
	var u struct {
		Login string `json:"login"`
	}
	if res.StatusCode != http.StatusOK || json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&u) != nil || u.Login == "" {
		return "", fmt.Errorf("%s did not answer as a Forgejo (%d for the account)", root, res.StatusCode)
	}
	return u.Login, nil
}

// ForgejoConnection is the connection a token makes on the Forgejo at root. URL is the root
// when it is not Codeberg's; Workspace is always its host, for the row to say which.
func ForgejoConnection(root, token, login string, at time.Time) Connection {
	c := Connection{Provider: Forgejo, Login: login, Access: token, ConnectedAt: at}
	if !IsCodeberg(root) {
		c.URL = root
	}
	if u, err := url.Parse(root); err == nil {
		c.Workspace = u.Host
	}
	return c
}
