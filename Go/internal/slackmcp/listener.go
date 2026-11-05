package slackmcp

import (
	"context"
	"errors"
	"log/slog"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"
	"github.com/slack-go/slack/socketmode"
)

// The listener holds the Socket Mode connection open while the server runs, acknowledges
// each request at once (Slack wants it inside three seconds), and puts the messages and
// the answers into the inbox. A dropped connection opens again, slower after each failure.
// Slack shares an app's events between its open connections, so run one server per app.

// questionBlock starts the block_id of the options ask_question posts; the id follows.
const questionBlock = "agents-question:"

const (
	firstRetry = 5 * time.Second
	lastRetry  = 5 * time.Minute
	maxAnswers = 1000
)

// Listener fills an Inbox from Slack.
type Listener struct {
	Workspace *Workspace
	Inbox     *Inbox
	Logger    *slog.Logger

	mu       sync.Mutex
	refused  error
	answered map[string]bool
}

// Refused is why Slack last refused the tokens, or nil.
func (l *Listener) Refused() error {
	if l == nil {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.refused
}

func (l *Listener) refuse(err error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.refused = err
}

// Run listens until ctx ends. With no tokens it returns at once.
func (l *Listener) Run(ctx context.Context) {
	api, err := l.Workspace.client()
	if err != nil {
		return
	}
	wait := firstRetry
	for ctx.Err() == nil {
		if _, err := l.Workspace.whoami(ctx); err != nil {
			l.refuse(err)
		} else if l.listen(ctx, socketmode.New(api)) {
			wait = firstRetry
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
		wait = min(lastRetry, wait*2)
	}
}

// listen runs one Socket Mode client until it stops; true when it connected.
func (l *Listener) listen(ctx context.Context, smc *socketmode.Client) bool {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- smc.RunContext(ctx) }()
	connected := false
	for {
		select {
		case err := <-done:
			if err != nil && ctx.Err() == nil {
				l.Logger.Warn("slack: socket mode stopped", "err", err)
			}
			return connected
		case evt := <-smc.Events:
			if evt.Request != nil && evt.Request.EnvelopeID != "" {
				_ = smc.AckCtx(ctx, evt.Request.EnvelopeID, nil)
			}
			switch evt.Type {
			case socketmode.EventTypeConnected:
				connected = true
				l.refuse(nil)
			case socketmode.EventTypeInvalidAuth:
				l.refuse(errors.New("slack refused the app-level token: set SLACK_APP_TOKEN again (an xapp- token with connections:write, Socket Mode on)"))
				cancel()
			case socketmode.EventTypeEventsAPI:
				if e, ok := evt.Data.(slackevents.EventsAPIEvent); ok {
					l.eventsAPI(ctx, e)
				}
			case socketmode.EventTypeInteractive:
				if cb, ok := evt.Data.(slack.InteractionCallback); ok {
					l.interaction(ctx, cb)
				}
			}
		}
	}
}

// eventsAPI keeps a message: a message event, or an app_mention for an app that hears only
// those. Slack sends both for a mention; the inbox keeps one.
func (l *Listener) eventsAPI(ctx context.Context, e slackevents.EventsAPIEvent) {
	var m incoming
	switch ev := e.InnerEvent.Data.(type) {
	case *slackevents.MessageEvent:
		switch ev.SubType {
		case "", "thread_broadcast", "file_share":
		default:
			return // an edit, a deletion, a join, a bot's message
		}
		m = incoming{channel: ev.Channel, channelType: ev.ChannelType, user: ev.User, team: ev.UserTeam, ts: ev.TimeStamp,
			threadTs: ev.ThreadTimeStamp, text: ev.Text, bot: ev.BotID != ""}
	case *slackevents.AppMentionEvent:
		m = incoming{channel: ev.Channel, user: ev.User, team: ev.UserTeam, ts: ev.TimeStamp, threadTs: ev.ThreadTimeStamp,
			text: ev.Text, bot: ev.BotID != "", mention: true}
	default:
		return
	}
	if m.team == "" {
		m.team = e.TeamID
	}
	l.message(ctx, m)
}

// incoming is a message as the events say it.
type incoming struct {
	channel, channelType, user, team, ts, threadTs, text string
	bot, mention                                         bool
}

func (l *Listener) message(ctx context.Context, m incoming) {
	me, _ := l.Workspace.whoami(ctx)
	if m.bot || m.user == "" || m.user == me.user || m.channel == "" || m.ts == "" {
		return
	}
	if m.channelType == "" && strings.HasPrefix(m.channel, "D") {
		m.channelType = "im"
	}
	mentioned := m.mention || m.channelType == "im" || me.user != "" && strings.Contains(m.text, "<@"+me.user+">")
	thread := ""
	if m.threadTs != "" && m.threadTs != m.ts {
		thread = m.threadTs
	}
	data := map[string]any{"channel": m.channel, "channelType": m.channelType, "user": m.user, "team": m.team,
		"ts": m.ts, "threadTs": thread, "mentioned": mentioned}
	l.Inbox.add(item{id: MessageReceived + ":" + m.channel + ":" + m.ts, name: MessageReceived, at: tsTime(m.ts),
		data: data, sender: l.Workspace.sender(ctx, m.team, m.user),
		channel: m.channel, user: m.user, thread: thread, mentioned: mentioned})
}

// interaction keeps the first answer to a question, and makes the question say who answered
// so nobody presses it again.
func (l *Listener) interaction(ctx context.Context, cb slack.InteractionCallback) {
	if cb.Type != slack.InteractionTypeBlockActions {
		return
	}
	for _, act := range cb.ActionCallback.BlockActions {
		question, ok := strings.CutPrefix(act.BlockID, questionBlock)
		if !ok || question == "" {
			continue
		}
		index, err := strconv.Atoi(act.Value)
		if err != nil || !l.first(question) {
			return
		}
		channel := cb.Container.ChannelID
		if channel == "" {
			channel = cb.Channel.ID
		}
		ts := cb.Container.MessageTs
		if ts == "" {
			ts = cb.Message.Timestamp
		}
		team := cb.User.TeamID
		if team == "" {
			team = cb.Team.ID
		}
		option := act.Text.Text
		data := map[string]any{"question": question, "channel": channel, "ts": ts, "threadTs": cb.Container.ThreadTs,
			"user": cb.User.ID, "team": team, "option": option, "index": index}
		l.Inbox.add(item{id: QuestionAnswered + ":" + question, name: QuestionAnswered, at: time.Now(), data: data,
			sender: l.Workspace.sender(ctx, team, cb.User.ID), channel: channel, user: cb.User.ID, question: question})
		l.markAnswered(ctx, channel, ts, cb.Message.Text, cb.User.ID, option)
		return
	}
}

// first is true the first time a question is answered while the server runs.
func (l *Listener) first(question string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.answered[question] {
		return false
	}
	if l.answered == nil || len(l.answered) >= maxAnswers {
		l.answered = map[string]bool{}
	}
	l.answered[question] = true
	return true
}

// markAnswered puts the answer in place of the options.
func (l *Listener) markAnswered(ctx context.Context, channel, ts, question, user, option string) {
	api, err := l.Workspace.client()
	if err != nil || channel == "" || ts == "" {
		return
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	answer := "<@" + user + "> answered: *" + escape(option) + "*"
	blocks := []slack.Block{
		slack.NewSectionBlock(slack.NewTextBlockObject(slack.MarkdownType, question, false, false), nil, nil),
		slack.NewContextBlock("", slack.NewTextBlockObject(slack.MarkdownType, answer, false, false)),
	}
	if _, _, _, err := api.UpdateMessageContext(ctx, channel, ts, slack.MsgOptionText(question, false), slack.MsgOptionBlocks(blocks...)); err != nil {
		l.Logger.Warn("slack: could not mark the question answered", "err", said(err))
	}
}

// tsTime is a Slack ts (seconds.micro) as a time; now when it is not one.
func tsTime(ts string) time.Time {
	sec, micro, _ := strings.Cut(ts, ".")
	s, err := strconv.ParseInt(sec, 10, 64)
	if err != nil {
		return time.Now()
	}
	us, _ := strconv.ParseInt((micro + "000000")[:6], 10, 64)
	return time.Unix(s, us*1000)
}

// escape keeps text from being read as Slack's markup: a link, a mention, @channel.
func escape(text string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(text)
}
