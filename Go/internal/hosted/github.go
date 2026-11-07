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
// for a user token with the App's client secret, asks who it is and its verified primary
// email (#3388; the App's "Email addresses" permission), and forgets the token.

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
func (g gitHub) user(ctx context.Context, code string) (SignIn, error) {
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
		return SignIn{}, err
	}
	if token.AccessToken == "" {
		if token.Description != "" {
			return SignIn{}, errors.New(token.Description)
		}
		return SignIn{}, fmt.Errorf("GitHub gave no token (%s)", token.Error)
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
		return SignIn{}, err
	}
	if who.ID == 0 {
		return SignIn{}, errors.New("GitHub did not say who signed in")
	}
	user := gitHubSignIn(who.ID, who.Login)
	user.Created = who.Created
	user.Email = primaryEmail(ctx, g.api, token.AccessToken)
	return user, nil
}

// primaryEmail is a GitHub user's primary email, in lower case, when GitHub verified it;
// "" when it did not, or the App may not read emails.
func primaryEmail(ctx context.Context, api, token string) string {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, api+"/user/emails", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	var emails []struct {
		Email    string `json:"email"`
		Primary  bool   `json:"primary"`
		Verified bool   `json:"verified"`
	}
	if err := call(req, &emails); err != nil {
		return ""
	}
	for _, e := range emails {
		if e.Primary && e.Verified {
			return strings.ToLower(e.Email)
		}
	}
	return ""
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
