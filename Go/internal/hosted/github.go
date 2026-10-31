package hosted

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// The GitHub App's web sign-in (#1807): the browser goes to GitHub, and comes back to
// /signin/callback on this service's own domain with a code. The service trades the code
// for a user token with the App's client secret, asks who it is, and forgets the token.

type gitHub struct {
	clientID, secret string
	web, api         string
	redirect         string
}

var client = &http.Client{Timeout: 20 * time.Second}

// authorize is where the browser goes to sign in.
func (g gitHub) authorize(state string) string {
	q := url.Values{"client_id": {g.clientID}, "redirect_uri": {g.redirect}, "state": {state}}
	return g.web + "/login/oauth/authorize?" + q.Encode()
}

// user trades a code for the GitHub user it signed in.
func (g gitHub) user(ctx context.Context, code string) (GitHubID, error) {
	form := url.Values{"client_id": {g.clientID}, "client_secret": {g.secret}, "code": {code}, "redirect_uri": {g.redirect}}
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, g.web+"/login/oauth/access_token", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	var token struct {
		AccessToken string `json:"access_token"`
		Error       string `json:"error"`
		Description string `json:"error_description"`
	}
	if err := call(req, &token); err != nil {
		return GitHubID{}, err
	}
	if token.AccessToken == "" {
		if token.Description != "" {
			return GitHubID{}, errors.New(token.Description)
		}
		return GitHubID{}, fmt.Errorf("GitHub gave no token (%s)", token.Error)
	}
	req, _ = http.NewRequestWithContext(ctx, http.MethodGet, g.api+"/user", nil)
	req.Header.Set("Authorization", "Bearer "+token.AccessToken)
	req.Header.Set("Accept", "application/vnd.github+json")
	var who struct {
		ID      int64     `json:"id"`
		Login   string    `json:"login"`
		Created time.Time `json:"created_at"`
	}
	if err := call(req, &who); err != nil {
		return GitHubID{}, err
	}
	if who.ID == 0 {
		return GitHubID{}, errors.New("GitHub did not say who signed in")
	}
	return GitHubID{ID: who.ID, Login: who.Login, Created: who.Created}, nil
}

func call(req *http.Request, into any) error {
	res, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("GitHub could not be reached: %w", err)
	}
	defer res.Body.Close()
	body, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return err
	}
	if res.StatusCode != http.StatusOK {
		return fmt.Errorf("GitHub answered %s", res.Status)
	}
	return json.Unmarshal(body, into)
}
