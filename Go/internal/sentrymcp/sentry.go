package sentrymcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Sentry's REST API (#3583), with Go's own net/http: the sentry-go SDK sends errors and has
// no client for the API, and the official MCP server (getsentry/sentry-mcp) is TypeScript,
// with tools and no events. Two calls: an organization's issues, searched, and one issue,
// with its releases and its activity.

// DefaultURL is sentry.io; SENTRY_URL names another region (https://de.sentry.io) or a
// self-hosted Sentry.
const DefaultURL = "https://sentry.io"

// Account is where the server reads Sentry, as its environment set it.
type Account struct {
	Token  string
	Org    string
	URL    string
	Client *http.Client
}

// Connected is whether a token and an organization are set.
func (a *Account) Connected() bool {
	return a != nil && strings.TrimSpace(a.Token) != "" && strings.TrimSpace(a.Org) != ""
}

// ErrNotConnected is what an event says with no token or organization.
var ErrNotConnected = errors.New("no Sentry account: set SENTRY_AUTH_TOKEN and SENTRY_ORG in this connector's secrets")

// Kind is a failure's kind, as the events draft's errors need it.
type Kind int

const (
	Failed Kind = iota
	NotSignedIn
	RateLimited
	NotFound
)

// APIError is Sentry's refusal, in words, never the token.
type APIError struct {
	Kind         Kind
	Message      string
	RetryAfterMs int
}

func (e *APIError) Error() string { return e.Message }

// Issue is one Sentry issue, as the issues search and the issue's own page give it.
type Issue struct {
	ID        string `json:"id"`
	ShortID   string `json:"shortId"`
	Title     string `json:"title"`
	Culprit   string `json:"culprit"`
	Level     string `json:"level"`
	Status    string `json:"status"`
	Substatus string `json:"substatus"`
	Permalink string `json:"permalink"`
	FirstSeen string `json:"firstSeen"`
	LastSeen  string `json:"lastSeen"`
	Project   struct {
		ID   string `json:"id"`
		Slug string `json:"slug"`
	} `json:"project"`
}

// Details is what the issue's own page adds: the releases that first and last saw it, and
// what happened to it.
type Details struct {
	Issue
	FirstRelease *Release   `json:"firstRelease"`
	LastRelease  *Release   `json:"lastRelease"`
	Activity     []Activity `json:"activity"`
}

// Release is a release as an issue names it.
type Release struct {
	Version string `json:"version"`
}

// Activity is one thing that happened to an issue; set_regression is a regression, its data
// the release it came back in when Sentry knows it.
type Activity struct {
	Type        string         `json:"type"`
	DateCreated string         `json:"dateCreated"`
	Data        map[string]any `json:"data"`
}

// maxIssues is the most one search reads: Sentry's own page size.
const maxIssues = 100

func (a *Account) base() string {
	u := strings.TrimSpace(a.URL)
	if u == "" {
		u = DefaultURL
	}
	return strings.TrimSuffix(u, "/")
}

// Issues is the organization's issues that query finds, newest by sort ("new" is by first
// seen, "date" by last seen), over the last 14 days.
func (a *Account) Issues(ctx context.Context, query, sort, environment string) ([]Issue, error) {
	v := url.Values{"query": {query}, "sort": {sort}, "limit": {strconv.Itoa(maxIssues)}, "statsPeriod": {"14d"}}
	if environment != "" {
		v.Set("environment", environment)
	}
	var out []Issue
	err := a.get(ctx, "/api/0/organizations/"+url.PathEscape(a.Org)+"/issues/?"+v.Encode(), &out)
	return out, err
}

// Issue is one issue's own page.
func (a *Account) Issue(ctx context.Context, id string) (Details, error) {
	var out Details
	err := a.get(ctx, "/api/0/organizations/"+url.PathEscape(a.Org)+"/issues/"+url.PathEscape(id)+"/", &out)
	return out, err
}

func (a *Account) get(ctx context.Context, path string, into any) error {
	if !a.Connected() {
		return &APIError{Kind: NotSignedIn, Message: ErrNotConnected.Error()}
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, a.base()+path, nil)
	if err != nil {
		return &APIError{Message: "SENTRY_URL is not an address"}
	}
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(a.Token))
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "agents-sentry-mcp")
	client := a.Client
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return &APIError{Message: "Sentry could not be reached"}
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		return &APIError{Message: "Sentry's answer could not be read"}
	}
	switch {
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return &APIError{Kind: NotSignedIn, Message: fmt.Sprintf("Sentry refused the token (%d): it needs event:read, org:read and project:read", resp.StatusCode)}
	case resp.StatusCode == http.StatusNotFound:
		return &APIError{Kind: NotFound, Message: "Sentry has no organization " + a.Org}
	case resp.StatusCode == http.StatusTooManyRequests:
		wait := 60_000
		if s, err := strconv.Atoi(resp.Header.Get("Retry-After")); err == nil && s > 0 {
			wait = s * 1000
		}
		return &APIError{Kind: RateLimited, Message: "Sentry's rate limit", RetryAfterMs: wait}
	case resp.StatusCode < 200 || resp.StatusCode >= 300:
		return &APIError{Message: fmt.Sprintf("Sentry answered %d", resp.StatusCode)}
	}
	if err := json.Unmarshal(body, into); err != nil {
		return &APIError{Message: "Sentry's answer could not be read"}
	}
	return nil
}

// parseTime reads Sentry's times, with or without fractions of a second.
func parseTime(s string) (time.Time, bool) {
	t, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(s))
	if err != nil {
		return time.Time{}, false
	}
	return t.UTC(), true
}
