package connections

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

// The Agents GitHub App (#1335, registered by Alex 2026-10-18). The client ID is public:
// the device flow needs no client secret, at sign-in or at refresh, so there is none.
const (
	GitHubAppSlug  = "agents-loops"
	GitHubClientID = "Iv23liIROCArmZsCb0Y9"
	// GitHubInstallURL is where the person installs the App: a user token reaches only the
	// repositories where it is installed.
	GitHubInstallURL = "https://github.com/apps/" + GitHubAppSlug + "/installations/new"
)

// DeviceFlow is GitHub's device flow (RFC 8628) and its refresh, for a GitHub App.
type DeviceFlow struct {
	ClientID string
	// Base is github.com's root with a trailing slash; API is the REST API's. A test gives
	// a fake of each.
	Base, API string
	HTTP      *http.Client
	Now       func() time.Time
	// Sleep waits d or until ctx ends; a test gives one that does not wait.
	Sleep func(ctx context.Context, d time.Duration) error
}

// NewGitHubFlow is the flow for the Agents App on github.com.
func NewGitHubFlow() *DeviceFlow {
	return &DeviceFlow{ClientID: GitHubClientID, Base: "https://github.com/", API: "https://api.github.com/",
		HTTP: &http.Client{Timeout: 30 * time.Second}}
}

// DeviceCode is what the person is shown: the code to type at the verification address.
// DeviceCode itself is the flow's secret: it stays on the host.
type DeviceCode struct {
	DeviceCode      string
	UserCode        string
	VerificationURL string
	ExpiresAt       time.Time
	Interval        time.Duration
}

// Token is what an exchange or a refresh gives.
type Token struct {
	Access           string
	Refresh          string
	AccessExpiresAt  time.Time
	RefreshExpiresAt time.Time
}

// The ways a sign-in or a refresh ends without a token.
var (
	// ErrExpired: the code ended before the person approved it.
	ErrExpired = errors.New("the code expired before it was approved")
	// ErrDenied: the person pressed Cancel on github.com.
	ErrDenied = errors.New("the sign-in was denied on GitHub")
	// ErrRefused: GitHub refused the refresh token. The person signs in again.
	ErrRefused = errors.New("GitHub refused the refresh: sign in again")
)

// Failure is any other answer GitHub gave, in words: its error code, never a token.
type Failure struct{ Code, Words string }

func (f *Failure) Error() string {
	if f.Words != "" {
		return "GitHub said " + f.Code + ": " + f.Words
	}
	return "GitHub said " + f.Code
}

func (f *DeviceFlow) now() time.Time {
	if f.Now != nil {
		return f.Now()
	}
	return time.Now()
}

func (f *DeviceFlow) sleep(ctx context.Context, d time.Duration) error {
	if f.Sleep != nil {
		return f.Sleep(ctx, d)
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// oauthAnswer is every field the two endpoints answer with.
type oauthAnswer struct {
	DeviceCode            string `json:"device_code"`
	UserCode              string `json:"user_code"`
	VerificationURI       string `json:"verification_uri"`
	ExpiresIn             int    `json:"expires_in"`
	Interval              int    `json:"interval"`
	AccessToken           string `json:"access_token"`
	RefreshToken          string `json:"refresh_token"`
	RefreshTokenExpiresIn int    `json:"refresh_token_expires_in"`
	Error                 string `json:"error"`
	ErrorDescription      string `json:"error_description"`
}

// post sends form to path on Base and reads GitHub's JSON answer. A failure says what
// failed, never the form (which holds the device code or the refresh token).
func (f *DeviceFlow) post(ctx context.Context, path string, form url.Values) (oauthAnswer, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, f.Base+path, strings.NewReader(form.Encode()))
	if err != nil {
		return oauthAnswer{}, errors.New("the request to GitHub could not be made")
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	res, err := f.HTTP.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return oauthAnswer{}, ctx.Err()
		}
		return oauthAnswer{}, errors.New("GitHub could not be reached")
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	var a oauthAnswer
	if json.Unmarshal(b, &a) != nil {
		return oauthAnswer{}, fmt.Errorf("GitHub answered %d with no JSON", res.StatusCode)
	}
	if a.Error == "" && res.StatusCode != http.StatusOK {
		return oauthAnswer{}, fmt.Errorf("GitHub answered %d", res.StatusCode)
	}
	return a, nil
}

// Start asks for a device code and the code the person types.
func (f *DeviceFlow) Start(ctx context.Context) (DeviceCode, error) {
	a, err := f.post(ctx, "login/device/code", url.Values{"client_id": {f.ClientID}})
	if err != nil {
		return DeviceCode{}, err
	}
	if a.Error != "" {
		return DeviceCode{}, &Failure{Code: a.Error, Words: a.ErrorDescription}
	}
	if a.DeviceCode == "" || a.UserCode == "" || a.VerificationURI == "" {
		return DeviceCode{}, errors.New("GitHub gave no code")
	}
	interval := time.Duration(a.Interval) * time.Second
	if interval <= 0 {
		interval = 5 * time.Second
	}
	return DeviceCode{DeviceCode: a.DeviceCode, UserCode: a.UserCode, VerificationURL: a.VerificationURI,
		ExpiresAt: f.now().Add(time.Duration(a.ExpiresIn) * time.Second), Interval: interval}, nil
}

// Wait polls at the code's interval until the person approves or denies it, or it
// expires. slow_down adds the interval GitHub gives (5 s more when it gives none).
func (f *DeviceFlow) Wait(ctx context.Context, code DeviceCode) (Token, error) {
	interval := code.Interval
	for {
		if err := f.sleep(ctx, interval); err != nil {
			return Token{}, err
		}
		if !code.ExpiresAt.IsZero() && !f.now().Before(code.ExpiresAt) {
			return Token{}, ErrExpired
		}
		a, err := f.post(ctx, "login/oauth/access_token", url.Values{"client_id": {f.ClientID},
			"device_code": {code.DeviceCode}, "grant_type": {"urn:ietf:params:oauth:grant-type:device_code"}})
		if err != nil {
			if ctx.Err() != nil {
				return Token{}, ctx.Err()
			}
			// A network failure is tried again at the next interval, until the code ends.
			continue
		}
		switch a.Error {
		case "":
			return f.token(a)
		case "authorization_pending":
		case "slow_down":
			if a.Interval > 0 {
				interval = time.Duration(a.Interval) * time.Second
			} else {
				interval += 5 * time.Second
			}
		case "expired_token":
			return Token{}, ErrExpired
		case "access_denied":
			return Token{}, ErrDenied
		default:
			return Token{}, &Failure{Code: a.Error, Words: a.ErrorDescription}
		}
	}
}

// Refresh spends the refresh token for a new pair: GitHub's refresh tokens are single use.
func (f *DeviceFlow) Refresh(ctx context.Context, refresh string) (Token, error) {
	a, err := f.post(ctx, "login/oauth/access_token", url.Values{"client_id": {f.ClientID},
		"grant_type": {"refresh_token"}, "refresh_token": {refresh}})
	if err != nil {
		return Token{}, err
	}
	switch a.Error {
	case "":
		return f.token(a)
	case "bad_refresh_token", "unauthorized_client", "incorrect_client_credentials":
		return Token{}, ErrRefused
	}
	return Token{}, &Failure{Code: a.Error, Words: a.ErrorDescription}
}

func (f *DeviceFlow) token(a oauthAnswer) (Token, error) {
	if a.AccessToken == "" {
		return Token{}, errors.New("GitHub gave no token")
	}
	now := f.now()
	t := Token{Access: a.AccessToken, Refresh: a.RefreshToken}
	if a.ExpiresIn > 0 {
		t.AccessExpiresAt = now.Add(time.Duration(a.ExpiresIn) * time.Second)
	}
	if a.RefreshTokenExpiresIn > 0 {
		t.RefreshExpiresAt = now.Add(time.Duration(a.RefreshTokenExpiresIn) * time.Second)
	}
	return t, nil
}

// Login is the account the token is for: GET /user's login.
func (f *DeviceFlow) Login(ctx context.Context, access string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, f.API+"user", nil)
	if err != nil {
		return "", errors.New("the request to GitHub could not be made")
	}
	req.Header.Set("Authorization", "Bearer "+access)
	req.Header.Set("Accept", "application/vnd.github+json")
	res, err := f.HTTP.Do(req)
	if err != nil {
		return "", errors.New("GitHub could not be reached")
	}
	defer res.Body.Close()
	var u struct {
		Login string `json:"login"`
	}
	if res.StatusCode != http.StatusOK || json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&u) != nil || u.Login == "" {
		return "", fmt.Errorf("GitHub answered %d for the account", res.StatusCode)
	}
	return u.Login, nil
}

// Connection is the connection a new token makes for login.
func (t Token) Connection(provider, login string, at time.Time) Connection {
	return Connection{Provider: provider, Login: login, Access: t.Access, Refresh: t.Refresh,
		AccessExpiresAt: t.AccessExpiresAt, RefreshExpiresAt: t.RefreshExpiresAt, ConnectedAt: at}
}
