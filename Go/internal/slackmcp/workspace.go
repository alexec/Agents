package slackmcp

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/slack-go/slack"
)

// The Slack workspace the server speaks for (#1351): one Slack app, installed there, with a
// bot token (xoxb-) for the Web API and an app-level token (xapp-, connections:write) for
// Socket Mode, so no public address is needed. The tokens are never in an error or a log.

// Provider is the channel's kind, as a ChannelSender names it.
const Provider = "slack"

// ErrNotConnected is a call with no tokens.
var ErrNotConnected = errors.New("slack is not connected: set SLACK_BOT_TOKEN (xoxb-…) and SLACK_APP_TOKEN (xapp-…) " +
	"for a Slack app with Socket Mode on, installed in the workspace")

// Workspace is the bot's Slack.
type Workspace struct {
	BotToken string
	AppToken string
	// APIURL is Slack's Web API, ending in /; a fake's in tests.
	APIURL string

	once     sync.Once
	api      *slack.Client
	selfMu   sync.Mutex
	self     *self
	peopleMu sync.Mutex
	people   map[string]person
}

// self is who the bot is, and its workspace's address (https://<team>.slack.com/).
type self struct{ team, user, name, url string }

// person is a Slack user's name and email, as users.info said them, and when.
type person struct {
	name, email string
	at          time.Time
}

const (
	maxPeople = 500
	personTTL = time.Hour
)

// Connected is true when both tokens are set.
func (w *Workspace) Connected() bool {
	return strings.TrimSpace(w.BotToken) != "" && strings.TrimSpace(w.AppToken) != ""
}

// client is the Web API client, or ErrNotConnected.
func (w *Workspace) client() (*slack.Client, error) {
	if !w.Connected() {
		return nil, ErrNotConnected
	}
	w.once.Do(func() {
		options := []slack.Option{slack.OptionAppLevelToken(strings.TrimSpace(w.AppToken))}
		if w.APIURL != "" {
			options = append(options, slack.OptionAPIURL(w.APIURL))
		}
		w.api = slack.New(strings.TrimSpace(w.BotToken), options...)
	})
	return w.api, nil
}

// whoami is the bot's team and user, from auth.test once.
func (w *Workspace) whoami(ctx context.Context) (self, error) {
	w.selfMu.Lock()
	defer w.selfMu.Unlock()
	if w.self != nil {
		return *w.self, nil
	}
	api, err := w.client()
	if err != nil {
		return self{}, err
	}
	r, err := api.AuthTestContext(ctx)
	if err != nil {
		return self{}, said(err)
	}
	w.self = &self{team: r.TeamID, user: r.UserID, name: r.User, url: r.URL}
	return *w.self, nil
}

// personOf is a user's name and email (users:read, users:read.email), kept an hour; empty
// when Slack does not say.
func (w *Workspace) personOf(ctx context.Context, user string) person {
	w.peopleMu.Lock()
	if p, ok := w.people[user]; ok && time.Since(p.at) < personTTL {
		w.peopleMu.Unlock()
		return p
	}
	w.peopleMu.Unlock()
	api, err := w.client()
	if err != nil {
		return person{}
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	u, err := api.GetUserInfoContext(ctx, user)
	if err != nil {
		return person{}
	}
	p := person{name: u.Profile.DisplayName, email: strings.ToLower(u.Profile.Email), at: time.Now()}
	if p.name == "" {
		p.name = u.Profile.RealName
	}
	if p.name == "" {
		p.name = u.Name
	}
	w.peopleMu.Lock()
	defer w.peopleMu.Unlock()
	if w.people == nil || len(w.people) >= maxPeople {
		w.people = map[string]person{}
	}
	w.people[user] = p
	return p
}

// sender is who sent a message or pressed a button, for a channel link (#1762): the
// identity is team/user, as a user id is unique only in its team.
func (w *Workspace) sender(ctx context.Context, team, user string) map[string]any {
	s := map[string]any{"channel": Provider, "identity": team + "/" + user}
	p := w.personOf(ctx, user)
	if p.name != "" {
		s["name"] = p.name
	}
	if p.email != "" {
		s["email"] = p.email
	}
	return s
}

// said is a Slack error in words that say what to do; never a token.
func said(err error) error {
	var limited *slack.RateLimitedError
	if errors.As(err, &limited) {
		return fmt.Errorf("slack: rate limited; try again in %s", limited.RetryAfter.Round(time.Second))
	}
	var e slack.SlackErrorResponse
	if !errors.As(err, &e) {
		return fmt.Errorf("slack: %w", err)
	}
	switch e.Err {
	case "not_authed", "invalid_auth", "account_inactive", "token_revoked", "token_expired":
		return fmt.Errorf("slack: the bot token is not valid (%s): set SLACK_BOT_TOKEN again", e.Err)
	case "missing_scope":
		return fmt.Errorf("slack: the app is missing the scope %s; add it under OAuth & Permissions and reinstall the app", e.Needed)
	case "channel_not_found":
		return fmt.Errorf("slack: no such channel, or the bot cannot see it: list_conversations lists the ones it is in")
	case "not_in_channel":
		return fmt.Errorf("slack: the bot is not in that channel: invite it with /invite @<the app>")
	case "thread_not_found", "message_not_found":
		return fmt.Errorf("slack: no such message in that channel (%s)", e.Err)
	}
	return fmt.Errorf("slack: %s", e.Err)
}
