package channels

import (
	"context"
	"strings"
	"sync"
	"unicode"
)

// Handling is ChannelHandling: the channels as the control plane's methods see them.
type Handling interface {
	State() ChannelsState
	Set(request ChannelsSet) (ChannelsState, error)
}

// Hooks is Channels.Hooks: what the service hands the channels.
type Hooks struct {
	// Settings is control.json's channels, or nil for none set.
	Settings func() *ChannelSettings
	// Save writes control.json's channels.
	Save func(ChannelSettings) error
	// Changed tells every client control/channelsChanged.
	Changed func(ChannelsState)
	// Slack makes a Slack channel for these tokens and member; tests give a fake Slack.
	Slack func(tokens SlackTokens, memberID string) NeedsChannel
}

// File names: Channels.fileName, .appTokenName and .botTokenName.
const (
	FileName     = "channels.env"
	AppTokenName = "SLACK_APP_TOKEN"
	BotTokenName = "SLACK_BOT_TOKEN"
)

type runningSlack struct {
	channel NeedsChannel
	tokens  SlackTokens
	member  string
}

// Channels is Channels: how each channel is set, its secrets, and the one running. Only
// Slack for now. What is set lives in control.json; the tokens live in
// <home>/.agents-secrets/channels.env and are written, never sent back.
type Channels struct {
	hooks   Hooks
	secrets string
	// Desk is between the hosts' needs and the running channel: attention/need goes to
	// Desk.Post.
	Desk *Desk

	// op makes Set, Apply and Stop one at a time.
	op sync.Mutex

	mu      sync.Mutex
	running *runningSlack
	status  string
	detail  *string
}

var _ Handling = (*Channels)(nil)

// New is Channels.init(secretsHome:desk:hooks:). home holds .agents-secrets/channels.env.
func New(secretsHome string, desk *Desk, hooks Hooks) *Channels {
	return &Channels{hooks: hooks, secrets: SecretsPath(secretsHome, FileName), Desk: desk, status: StatusOff}
}

func (c *Channels) slackSettings() SlackChannelSettings {
	if s := c.hooks.Settings(); s != nil && s.Slack != nil {
		return *s.Slack
	}
	return SlackChannelSettings{}
}

// State is Channels.state: how each channel is set and how it stands. Never a token.
func (c *Channels) State() ChannelsState {
	slack := c.slackSettings()
	env := LoadSecrets(c.secrets)
	app, _ := env.Value(AppTokenName)
	bot, _ := env.Value(BotTokenName)
	c.mu.Lock()
	status, detail := c.status, c.detail
	c.mu.Unlock()
	return ChannelsState{Slack: SlackState{Enabled: slack.Enabled, MemberID: slack.MemberID,
		AppTokenSet: app != "", BotTokenSet: bot != "", Status: status, Detail: detail, Available: true}}
}

// Set is Channels.set: channels/set. Only what is given changes.
func (c *Channels) Set(request ChannelsSet) (ChannelsState, error) {
	c.op.Lock()
	defer c.op.Unlock()
	if change := request.Slack; change != nil {
		slack := c.slackSettings()
		if change.MemberID != nil {
			member := strings.TrimSpace(*change.MemberID)
			if member != "" && !IsMemberID(member) {
				return ChannelsState{}, &RPCError{Code: CodeInvalidParams,
					Message: "That isn’t a Slack member ID. In Slack, open your profile, then ⋯ ▸ Copy member ID: it starts with U."}
			}
			slack.MemberID = member
		}
		if change.Enabled != nil {
			slack.Enabled = *change.Enabled
		}
		if change.AppToken != nil || change.BotToken != nil {
			if err := c.saveTokens(change.AppToken, change.BotToken); err != nil {
				return ChannelsState{}, err
			}
		}
		if err := c.hooks.Save(ChannelSettings{Slack: &slack}); err != nil {
			return ChannelsState{}, err
		}
	}
	c.apply()
	now := c.State()
	c.hooks.Changed(now)
	return now, nil
}

// saveTokens is Channels.saveTokens: tokens written, trimmed; an empty one taken away.
// Each is checked for its kind.
func (c *Channels) saveTokens(app, bot *string) error {
	env, err := LoadSecretsForChange(c.secrets)
	if err != nil {
		return &RPCError{Code: CodeNotPermitted,
			Message: c.secrets + " could not be read, so nothing was written to it. Check its permissions."}
	}
	for _, t := range []struct {
		name   string
		value  *string
		prefix string
		kind   string
	}{{AppTokenName, app, "xapp-", "app"}, {BotTokenName, bot, "xoxb-", "bot"}} {
		if t.value == nil {
			continue
		}
		value := strings.TrimSpace(*t.value)
		if value == "" {
			env.Remove(t.name)
			continue
		}
		if !strings.HasPrefix(value, t.prefix) || strings.IndexFunc(value, unicode.IsSpace) >= 0 {
			return &RPCError{Code: CodeInvalidParams, Message: "A Slack " + t.kind + " token starts with " + t.prefix + "."}
		}
		env.Set(t.name, value)
	}
	return env.Save(c.secrets)
}

// Apply is Channels.apply: Slack running as set, started, restarted with new tokens or
// member, or stopped. The service calls it once when it starts.
func (c *Channels) Apply() {
	c.op.Lock()
	defer c.op.Unlock()
	c.apply()
}

func (c *Channels) apply() {
	slack := c.slackSettings()
	env := LoadSecrets(c.secrets)
	app, _ := env.Value(AppTokenName)
	bot, _ := env.Value(BotTokenName)
	var wanted *runningSlack
	why := ""
	if slack.Enabled {
		switch {
		case app == "" || bot == "":
			why = "Set both Slack tokens."
		case !IsMemberID(slack.MemberID):
			why = "Set your Slack member ID."
		default:
			wanted = &runningSlack{tokens: SlackTokens{App: app, Bot: bot}, member: slack.MemberID}
		}
	}
	c.mu.Lock()
	running := c.running
	c.mu.Unlock()
	if running != nil && wanted != nil && running.tokens == wanted.tokens && running.member == wanted.member {
		return
	}
	if running != nil {
		running.channel.Stop()
		c.Desk.Use(nil)
		c.mu.Lock()
		c.running = nil
		c.mu.Unlock()
	}
	if wanted == nil {
		if why == "" {
			c.report(StatusOff, nil)
		} else {
			c.report(StatusFailed, &why)
		}
		return
	}
	channel := c.hooks.Slack(wanted.tokens, wanted.member)
	wanted.channel = channel
	c.mu.Lock()
	c.running = wanted
	c.mu.Unlock()
	c.Desk.Use(channel)
	desk := c.Desk
	channel.Start(func(reply ChannelReply) { desk.HeardReply(context.Background(), reply) },
		func(status ChannelStatus) { c.heard(status, channel) })
}

// Stop is Channels.stop.
func (c *Channels) Stop() {
	c.op.Lock()
	defer c.op.Unlock()
	c.mu.Lock()
	running := c.running
	c.running = nil
	c.mu.Unlock()
	if running != nil {
		running.channel.Stop()
	}
	c.Desk.Use(nil)
}

// heard is Channels.heard(_:from:): a status from the running channel, and only that one.
func (c *Channels) heard(change ChannelStatus, channel NeedsChannel) {
	c.mu.Lock()
	current := c.running != nil && c.running.channel == channel
	c.mu.Unlock()
	if !current {
		return
	}
	switch change.State {
	case StatusConnecting, StatusConnected:
		c.report(change.State, nil)
	case StatusFailed:
		words := change.Words
		c.report(StatusFailed, &words)
	}
}

// report is Channels.report: a new status, told to every client.
func (c *Channels) report(status string, detail *string) {
	c.mu.Lock()
	if status == c.status && equalDetail(detail, c.detail) {
		c.mu.Unlock()
		return
	}
	c.status, c.detail = status, detail
	c.mu.Unlock()
	c.hooks.Changed(c.State())
}

func equalDetail(a, b *string) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}
