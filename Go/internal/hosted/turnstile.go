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
)

// Cloudflare Turnstile on the sign-up page (#3388, decided in #3387): with its keys set,
// the page's buttons are one form with Turnstile's widget, posted to /signin, and the
// service asks Cloudflare's siteverify if the widget's token passed before it sends the
// browser to the provider. A GET of /signin goes back to the page. Only the sign-up page
// has it: a control plane's join and sign-in need a person who has an account already.
// With no keys there is no Turnstile, so a self-hosted or local copy needs no Cloudflare.
//
// Siteverify is one form post and a JSON answer, so the standard library makes it; no
// Cloudflare SDK is needed.

const (
	turnstileAPI = "https://challenges.cloudflare.com/turnstile/v0/siteverify"
	// turnstileScript is the widget, and the origin the page's CSP lets it load from.
	turnstileOrigin = "https://challenges.cloudflare.com"
	turnstileScript = turnstileOrigin + "/turnstile/v0/api.js"
	// turnstileField is the form field the widget puts its token in.
	turnstileField = "cf-turnstile-response"
	// A token is at most 2048 characters.
	turnstileMost = 2048
)

type turnstile struct {
	siteKey, secret, api string
	http                 *http.Client
}

func newTurnstile(siteKey, secret, api string, hc *http.Client) *turnstile {
	if api == "" {
		api = turnstileAPI
	}
	if hc == nil {
		hc = client
	}
	return &turnstile{siteKey: siteKey, secret: secret, api: api, http: hc}
}

// errNotPerson is a token Cloudflare says did not pass.
var errNotPerson = errors.New("the Turnstile check did not pass")

// check asks Cloudflare whether a widget's token passed, for the person at from.
func (t *turnstile) check(ctx context.Context, token, from string) error {
	if token == "" || len(token) > turnstileMost {
		return errNotPerson
	}
	form := url.Values{"secret": {t.secret}, "response": {token}}
	if from != "" {
		form.Set("remoteip", from)
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, t.api, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := t.http.Do(req)
	if err != nil {
		return fmt.Errorf("Turnstile could not be reached: %w", err)
	}
	defer res.Body.Close()
	body, err := io.ReadAll(io.LimitReader(res.Body, 1<<16))
	if err != nil {
		return err
	}
	if res.StatusCode != http.StatusOK {
		return fmt.Errorf("Turnstile answered %s", res.Status)
	}
	var answer struct {
		Success bool     `json:"success"`
		Errors  []string `json:"error-codes"`
	}
	if err := json.Unmarshal(body, &answer); err != nil {
		return fmt.Errorf("Turnstile's answer: %w", err)
	}
	if !answer.Success {
		return fmt.Errorf("%w (%s)", errNotPerson, strings.Join(answer.Errors, ", "))
	}
	return nil
}
