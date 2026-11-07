package connections

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Bitbucket is the seventh provider (#3785): a token on Bitbucket Cloud, as the bitbucket
// server takes it. With the account's email, an Atlassian API token with the Bitbucket scopes
// (Basic); without, a repository, project or workspace access token (Bearer). Bitbucket has
// no device flow, and a token has no refresh: it ends only on the date the person gave it on
// Atlassian, or when they delete it.
const Bitbucket = "bitbucket"

// BitbucketAPI is Bitbucket Cloud's REST API 2.0, the API a connection is on when no other is
// given.
const BitbucketAPI = "https://api.bitbucket.org/2.0/"

// BitbucketSite is Bitbucket Cloud's host, as a connection's row says it.
const BitbucketSite = "bitbucket.org"

// BitbucketRoot is raw as Bitbucket's API root with a trailing slash: Bitbucket Cloud's when
// blank, https:// when it names no scheme. http is taken only for this machine (a fake
// Bitbucket in a walk).
func BitbucketRoot(raw string) (string, error) { return forgeRoot(raw, BitbucketAPI, "Bitbucket", "") }

// BitbucketHeader is the Authorization header for token: Basic with the account's email for an
// Atlassian API token, Bearer for an access token.
func BitbucketHeader(email, token string) string {
	if email = strings.TrimSpace(email); email != "" {
		return "Basic " + base64.StdEncoding.EncodeToString([]byte(email+":"+token))
	}
	return "Bearer " + token
}

// CheckBitbucketToken asks the Bitbucket API at api whose token this is, and gives the
// account's nickname (its display name when it has none). The token goes only in the
// Authorization header; an error never holds it.
func CheckBitbucketToken(ctx context.Context, client *http.Client, api, email, token string) (string, error) {
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, api+"user", nil)
	if err != nil {
		return "", errors.New("the request to Bitbucket could not be made")
	}
	req.Header.Set("Authorization", BitbucketHeader(email, token))
	req.Header.Set("Accept", "application/json")
	res, err := client.Do(req)
	if err != nil {
		return "", errors.New("Bitbucket could not be reached")
	}
	defer res.Body.Close()
	if res.StatusCode == http.StatusUnauthorized {
		if strings.TrimSpace(email) != "" {
			return "", errors.New("Bitbucket did not take the email and API token")
		}
		return "", errors.New("Bitbucket did not take the token. For an Atlassian API token, give its account's email too")
	}
	if res.StatusCode == http.StatusForbidden {
		// A token without the account scope's read can't say whose it is.
		return "", errors.New("the token can't read its account: give it read on account, and read and write on repositories, pull requests and issues")
	}
	var u struct {
		Nickname    string `json:"nickname"`
		DisplayName string `json:"display_name"`
	}
	if res.StatusCode != http.StatusOK || json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&u) != nil {
		return "", fmt.Errorf("%s did not answer as Bitbucket (%d for the account)", api, res.StatusCode)
	}
	if u.Nickname != "" {
		return u.Nickname, nil
	}
	return u.DisplayName, nil
}

// BitbucketConnection is the connection a token makes on the Bitbucket API at api. URL is the
// API when it is not Bitbucket Cloud's; User is the email an API token is sent with.
func BitbucketConnection(api, email, token, login string, at time.Time) Connection {
	c := Connection{Provider: Bitbucket, Login: login, User: strings.TrimSpace(email), Access: token, Workspace: BitbucketSite, ConnectedAt: at}
	if api != BitbucketAPI {
		c.URL = api
	}
	return c
}
