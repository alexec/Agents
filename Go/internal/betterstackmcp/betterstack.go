package betterstackmcp

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

// Better Stack's Uptime API (#3655), with Go's own net/http: Better Stack has no Go SDK, and
// its official MCP server (mcp.betterstack.com) is a remote one with tools and no events.
// One call: the incidents, by the day they started, a page of at most 50 at a time.

// DefaultURL is Better Stack's incidents API; BETTERSTACK_URL names another.
const DefaultURL = "https://incidents.betterstack.com"

// Account is where the server reads Better Stack, as its environment set it.
type Account struct {
	Token string
	// Team is the team's name, for a global token; a team's own token leaves it out.
	Team   string
	URL    string
	Client *http.Client
}

// Connected is whether a token is set.
func (a *Account) Connected() bool {
	return a != nil && strings.TrimSpace(a.Token) != ""
}

// ErrNotConnected is what an event says with no token.
var ErrNotConnected = errors.New("no Better Stack account: set BETTERSTACK_API_TOKEN in this connector's secrets")

// Kind is a failure's kind, as the events draft's errors need it.
type Kind int

const (
	Failed Kind = iota
	NotSignedIn
	RateLimited
	NotFound
)

// APIError is Better Stack's refusal, in words, never the token.
type APIError struct {
	Kind         Kind
	Message      string
	RetryAfterMs int
}

func (e *APIError) Error() string { return e.Message }

// Incident is one Better Stack incident: a monitor or a heartbeat that failed.
type Incident struct {
	ID         string `json:"id"`
	Attributes struct {
		Name       string  `json:"name"`
		URL        string  `json:"url"`
		Cause      string  `json:"cause"`
		StartedAt  string  `json:"started_at"`
		ResolvedAt *string `json:"resolved_at"`
		Status     string  `json:"status"`
		TeamName   string  `json:"team_name"`
	} `json:"attributes"`
	Relationships struct {
		Monitor struct {
			Data *struct {
				ID string `json:"id"`
			} `json:"data"`
		} `json:"monitor"`
	} `json:"relationships"`
}

// MonitorID is the incident's monitor, empty for a heartbeat's.
func (i Incident) MonitorID() string {
	if d := i.Relationships.Monitor.Data; d != nil {
		return d.ID
	}
	return ""
}

type page struct {
	Data       []Incident `json:"data"`
	Pagination struct {
		Next *string `json:"next"`
	} `json:"pagination"`
}

const (
	// perPage is Better Stack's largest page.
	perPage = 50
	// maxPages is the most pages one read follows.
	maxPages = 4
)

func (a *Account) base() string {
	u := strings.TrimSpace(a.URL)
	if u == "" {
		u = DefaultURL
	}
	return strings.TrimSuffix(u, "/")
}

// Incidents is the incidents that started on from's day or later, resolved only or all;
// truncated when Better Stack had more than maxPages pages.
func (a *Account) Incidents(ctx context.Context, from time.Time, monitor string, resolved bool) ([]Incident, bool, error) {
	v := url.Values{"from": {from.UTC().Format("2006-01-02")}, "per_page": {strconv.Itoa(perPage)}}
	if monitor != "" {
		v.Set("monitor_id", monitor)
	}
	if resolved {
		v.Set("resolved", "true")
	}
	if team := strings.TrimSpace(a.Team); team != "" {
		v.Set("team_name", team)
	}
	next := a.base() + "/api/v3/incidents?" + v.Encode()
	var out []Incident
	for range maxPages {
		var p page
		if err := a.get(ctx, next, &p); err != nil {
			return nil, false, err
		}
		out = append(out, p.Data...)
		if p.Pagination.Next == nil || *p.Pagination.Next == "" {
			return out, false, nil
		}
		// The next page is on the same host: a link elsewhere would take the token there.
		n, err := url.Parse(*p.Pagination.Next)
		b, _ := url.Parse(a.base())
		if err != nil || b == nil || n.Host != b.Host {
			return out, true, nil
		}
		next = b.Scheme + "://" + b.Host + n.RequestURI()
	}
	return out, true, nil
}

func (a *Account) get(ctx context.Context, address string, into any) error {
	if !a.Connected() {
		return &APIError{Kind: NotSignedIn, Message: ErrNotConnected.Error()}
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return &APIError{Message: "BETTERSTACK_URL is not an address"}
	}
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(a.Token))
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "agents-betterstack-mcp")
	client := a.Client
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return &APIError{Message: "Better Stack could not be reached"}
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		return &APIError{Message: "Better Stack's answer could not be read"}
	}
	switch {
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return &APIError{Kind: NotSignedIn, Message: fmt.Sprintf("Better Stack refused the token (%d): it needs an Uptime API token", resp.StatusCode)}
	case resp.StatusCode == http.StatusNotFound:
		return &APIError{Kind: NotFound, Message: "Better Stack has no such team or monitor"}
	case resp.StatusCode == http.StatusTooManyRequests:
		wait := 60_000
		if s, err := strconv.Atoi(resp.Header.Get("Retry-After")); err == nil && s > 0 {
			wait = s * 1000
		}
		return &APIError{Kind: RateLimited, Message: "Better Stack's rate limit", RetryAfterMs: wait}
	case resp.StatusCode < 200 || resp.StatusCode >= 300:
		return &APIError{Message: fmt.Sprintf("Better Stack answered %d", resp.StatusCode)}
	}
	if err := json.Unmarshal(body, into); err != nil {
		return &APIError{Message: "Better Stack's answer could not be read"}
	}
	return nil
}

// parseTime reads Better Stack's times, with or without fractions of a second.
func parseTime(s string) (time.Time, bool) {
	t, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(s))
	if err != nil {
		return time.Time{}, false
	}
	return t.UTC(), true
}
