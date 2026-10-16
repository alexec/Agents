package channels

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/safe"
)

// SlackTransport is SlackTransport: how the channel reaches Slack, the Web API and a
// Socket Mode socket. Tests give it a fake Slack.
type SlackTransport interface {
	// Call is https://slack.com/api/<method> with a token: the reply when ok, else a
	// *SlackFailure.
	Call(ctx context.Context, method, token string, body map[string]any) (map[string]any, error)
	Connect(ctx context.Context, url string) (LineConn, error)
}

// LineConn is LineTransport as Socket Mode uses it: one envelope a line.
type LineConn interface {
	// ReadLine gives the next line; io.EOF when the socket closed.
	ReadLine(ctx context.Context) (string, error)
	WriteLine(line string) error
	Close() error
}

// SlackFailure is SlackFailure: something Slack refused, in words a person can act on.
type SlackFailure struct{ Words string }

func (f *SlackFailure) Error() string { return f.Words }

// SlackSaid is SlackFailure.said(_:method:): Slack's error code, said so a person knows
// what to fix.
func SlackSaid(code, method string) *SlackFailure {
	switch code {
	case "invalid_auth", "not_authed", "account_inactive", "token_revoked":
		return &SlackFailure{fmt.Sprintf("Slack refused the token for %s (%s). Check the app and bot tokens.", method, code)}
	case "missing_scope":
		return &SlackFailure{fmt.Sprintf("The Slack app lacks a scope %s needs. Add the scopes in the set-up steps and reinstall it.", method)}
	case "user_not_found", "users_not_found":
		return &SlackFailure{"Slack knows no member with that ID in this workspace."}
	}
	return &SlackFailure{fmt.Sprintf("Slack refused %s: %s.", method, code)}
}

// SlackTokens is SlackChannel.Tokens: the app token (xapp-, Socket Mode) and the bot
// token (xoxb-, for messages). Neither is ever logged.
type SlackTokens struct {
	App string
	Bot string
}

// SlackBackoff is SlackChannel.backoff: 2, 4, 8 … seconds, at most two minutes.
func SlackBackoff(attempt int) time.Duration {
	return time.Duration(min(120, 1<<min(attempt+1, 7))) * time.Second
}

// slackPosted is SlackChannel.Posted: where a sent question is in Slack.
type slackPosted struct {
	channel, ts string
	message     NeedMessage
}

// SlackChannel is SlackChannel: Slack as a channel, over Socket Mode, so the control plane
// dials out and needs no public address. A question goes to the tied member's direct
// messages with its options as buttons; a button, or a reply in its thread, by that member
// only, answers it.
type SlackChannel struct {
	tokens    SlackTokens
	memberID  string
	transport SlackTransport
	retry     func(int) time.Duration
	log       func(string)

	mu     sync.Mutex
	posted map[string]slackPosted
	dm     string
	cancel context.CancelFunc
	socket LineConn
}

// NewSlackChannel is SlackChannel.init. retry and log may be nil for SlackBackoff and no log.
func NewSlackChannel(tokens SlackTokens, memberID string, transport SlackTransport,
	retry func(int) time.Duration, log func(string)) *SlackChannel {
	if retry == nil {
		retry = SlackBackoff
	}
	if log == nil {
		log = func(string) {}
	}
	return &SlackChannel{tokens: tokens, memberID: memberID, transport: transport, retry: retry, log: log,
		posted: map[string]slackPosted{}}
}

// Start is SlackChannel.start: connects, and connects again after a failure or when Slack
// says to go, until Stop.
func (s *SlackChannel) Start(heard func(ChannelReply), status func(ChannelStatus)) {
	ctx, cancel := context.WithCancel(context.Background())
	s.mu.Lock()
	if s.cancel != nil {
		s.cancel()
	}
	s.cancel = cancel
	s.mu.Unlock()
	safe.Go("slack channel", func() {
		attempt := 0
		for ctx.Err() == nil {
			status(ChannelStatus{State: StatusConnecting})
			err := func() error {
				address, err := s.socketURL(ctx)
				if err != nil {
					return err
				}
				socket, err := s.transport.Connect(ctx, address)
				if err != nil {
					return err
				}
				s.mu.Lock()
				s.socket = socket
				s.mu.Unlock()
				if ctx.Err() != nil {
					_ = socket.Close()
				}
				connected, err := s.read(ctx, socket, heard, status)
				if err == nil && connected {
					attempt = 0
				}
				return err
			}()
			if err != nil {
				if ctx.Err() != nil {
					break
				}
				status(ChannelStatus{State: StatusFailed, Words: err.Error()})
				s.log("slack: " + err.Error())
			}
			s.mu.Lock()
			s.socket = nil
			s.mu.Unlock()
			if ctx.Err() != nil {
				break
			}
			select {
			case <-ctx.Done():
			case <-time.After(s.retry(attempt)):
			}
			attempt++
		}
	})
}

// Stop is SlackChannel.stop.
func (s *SlackChannel) Stop() {
	s.mu.Lock()
	cancel, socket := s.cancel, s.socket
	s.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	if socket != nil {
		_ = socket.Close()
	}
}

// socketURL is SlackChannel.socketURL: apps.connections.open, an address good once.
func (s *SlackChannel) socketURL(ctx context.Context) (string, error) {
	reply, err := s.transport.Call(ctx, "apps.connections.open", s.tokens.App, map[string]any{})
	if err != nil {
		return "", err
	}
	text, _ := reply["url"].(string)
	if _, perr := url.Parse(text); text == "" || perr != nil {
		return "", &SlackFailure{"Slack gave no address to connect to."}
	}
	return text, nil
}

// read is SlackChannel.read: envelopes until Slack says to go or the socket closes. True
// when it was connected, so the next try comes soon.
func (s *SlackChannel) read(ctx context.Context, socket LineConn, heard func(ChannelReply),
	status func(ChannelStatus)) (bool, error) {
	connected := false
	partial := ""
	for {
		line, err := socket.ReadLine(ctx)
		if errors.Is(err, io.EOF) {
			return connected, nil
		}
		if err != nil {
			return connected, err
		}
		if partial == "" {
			partial = line
		} else {
			partial += "\n" + line
		}
		var decoded any
		if json.Unmarshal([]byte(partial), &decoded) != nil {
			// A frame cut at a newline; given up past a size no envelope reaches.
			if len(partial) > 1<<20 {
				partial = ""
			}
			continue
		}
		partial = ""
		envelope, _ := decoded.(map[string]any)
		// Every envelope is acknowledged at once, or Slack sends it again.
		if id, ok := envelope["envelope_id"].(string); ok {
			if ack, err := marshal(map[string]any{"envelope_id": id}); err == nil {
				_ = socket.WriteLine(string(ack))
			}
		}
		switch envelope["type"] {
		case "hello":
			connected = true
			status(ChannelStatus{State: StatusConnected})
			s.log("slack: connected")
		case "disconnect":
			// Slack moves connections now and then; it says so first.
			_ = socket.Close()
			return connected, nil
		case "interactive":
			if reply, ok := s.replyToAction(envelope["payload"]); ok {
				heard(reply)
			}
		case "events_api":
			payload, _ := envelope["payload"].(map[string]any)
			if reply, ok := s.replyToEvent(payload["event"]); ok {
				heard(reply)
			}
		}
	}
}

// replyToAction is SlackChannel.reply(toAction:): its block names the question, its value
// the option.
func (s *SlackChannel) replyToAction(raw any) (ChannelReply, bool) {
	payload, _ := raw.(map[string]any)
	if payload == nil || payload["type"] != "block_actions" {
		return ChannelReply{}, false
	}
	user, _ := payload["user"].(map[string]any)
	if user["id"] != s.memberID {
		return ChannelReply{}, false
	}
	actions, _ := payload["actions"].([]any)
	if len(actions) == 0 {
		return ChannelReply{}, false
	}
	action, _ := actions[0].(map[string]any)
	key, ok1 := action["block_id"].(string)
	value, ok2 := action["value"].(string)
	if !ok1 || !ok2 {
		return ChannelReply{}, false
	}
	s.mu.Lock()
	_, sent := s.posted[key]
	s.mu.Unlock()
	if !sent {
		return ChannelReply{}, false
	}
	return ChannelReply{Kind: Picked, Key: key, Value: value}, true
}

// replyToEvent is SlackChannel.reply(toEvent:): a message in a question's thread, in the
// direct messages, from the tied member.
func (s *SlackChannel) replyToEvent(raw any) (ChannelReply, bool) {
	event, _ := raw.(map[string]any)
	if event == nil || event["type"] != "message" || event["user"] != s.memberID {
		return ChannelReply{}, false
	}
	if _, ok := event["subtype"]; ok {
		return ChannelReply{}, false
	}
	if _, ok := event["bot_id"]; ok {
		return ChannelReply{}, false
	}
	thread, ok1 := event["thread_ts"].(string)
	text, ok2 := event["text"].(string)
	channel, ok3 := event["channel"].(string)
	if !ok1 || !ok2 || !ok3 {
		return ChannelReply{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for key, p := range s.posted {
		if p.channel == channel && p.ts == thread {
			return ChannelReply{Kind: Wrote, Key: key, Value: text}, true
		}
	}
	return ChannelReply{}, false
}

// Send is SlackChannel.send: the question to the member's direct messages.
func (s *SlackChannel) Send(ctx context.Context, message NeedMessage) error {
	channel, err := s.directMessages(ctx)
	if err != nil {
		return err
	}
	reply, err := s.transport.Call(ctx, "chat.postMessage", s.tokens.Bot, map[string]any{
		"channel": channel,
		"text":    slackFallback(message),
		"blocks":  slackBlocks(message, nil),
	})
	if err != nil {
		return err
	}
	ts, ok := reply["ts"].(string)
	if !ok {
		return &SlackFailure{"Slack didn't say where the message went."}
	}
	s.mu.Lock()
	s.posted[message.Key] = slackPosted{channel: channel, ts: ts, message: message}
	s.mu.Unlock()
	return nil
}

// Close is SlackChannel.close: the message loses its buttons and says why.
func (s *SlackChannel) Close(ctx context.Context, key, saying string) {
	s.mu.Lock()
	sent, ok := s.posted[key]
	delete(s.posted, key)
	s.mu.Unlock()
	if !ok {
		return
	}
	_, err := s.transport.Call(ctx, "chat.update", s.tokens.Bot, map[string]any{
		"channel": sent.channel, "ts": sent.ts,
		"text":   slackFallback(sent.message) + " — " + saying,
		"blocks": slackBlocks(sent.message, &saying),
	})
	if err != nil {
		s.log("slack: could not close a question: " + err.Error())
	}
}

// Note is SlackChannel.note: a reply in the question's thread.
func (s *SlackChannel) Note(ctx context.Context, key, text string) {
	s.mu.Lock()
	sent, ok := s.posted[key]
	s.mu.Unlock()
	if !ok {
		return
	}
	_, err := s.transport.Call(ctx, "chat.postMessage", s.tokens.Bot, map[string]any{
		"channel": sent.channel, "thread_ts": sent.ts, "text": text,
	})
	if err != nil {
		s.log("slack: could not reply in a thread: " + err.Error())
	}
}

// directMessages is SlackChannel.directMessages: the direct messages with the member,
// opened once.
func (s *SlackChannel) directMessages(ctx context.Context) (string, error) {
	s.mu.Lock()
	dm := s.dm
	s.mu.Unlock()
	if dm != "" {
		return dm, nil
	}
	reply, err := s.transport.Call(ctx, "conversations.open", s.tokens.Bot, map[string]any{"users": s.memberID})
	if err != nil {
		return "", err
	}
	channel, _ := reply["channel"].(map[string]any)
	id, ok := channel["id"].(string)
	if !ok {
		return "", &SlackFailure{fmt.Sprintf("Slack wouldn't open direct messages with %s.", s.memberID)}
	}
	s.mu.Lock()
	s.dm = id
	s.mu.Unlock()
	return id, nil
}

// slackFallback is SlackChannel.fallback: the notification's words.
func slackFallback(m NeedMessage) string {
	heading := m.Heading
	if heading == "" {
		heading = "An agent"
	}
	return heading + " needs you: " + m.Question
}

// slackBlocks is SlackChannel.blocks: the question's blocks; with closing, without its
// buttons and with why it closed. The actions block's id is the question's key.
func slackBlocks(m NeedMessage, closing *string) []any {
	context := func(text string) map[string]any {
		return map[string]any{"type": "context", "elements": []any{map[string]any{"type": "mrkdwn", "text": text}}}
	}
	var blocks []any
	if m.Heading != "" {
		blocks = append(blocks, context(slackEscape(m.Heading)))
	}
	text := "*" + slackEscape(m.Question) + "*"
	if m.Detail != "" {
		text += "\n" + slackEscape(m.Detail)
	}
	blocks = append(blocks, map[string]any{"type": "section", "text": map[string]any{"type": "mrkdwn", "text": prefix(text, 3000)}})
	if closing != nil {
		return append(blocks, context(slackEscape(*closing)))
	}
	if len(m.Options) > 0 {
		var buttons []any
		for i, o := range m.Options {
			if i == 25 {
				break
			}
			buttons = append(buttons, map[string]any{
				"type": "button", "action_id": fmt.Sprintf("option-%d", i),
				"text":  map[string]any{"type": "plain_text", "text": prefix(o.Title, 75), "emoji": true},
				"value": prefix(o.Value, 2000),
			})
		}
		blocks = append(blocks, map[string]any{"type": "actions", "block_id": m.Key, "elements": buttons})
	}
	hint := "Press one."
	switch {
	case m.AnswerElsewhere:
		hint = "Answer this one in Agents."
	case len(m.Options) == 0:
		hint = "Reply in this thread to answer."
	case m.TakesText:
		hint = "Press one, or reply in this thread."
	}
	return append(blocks, context(hint))
}

// slackEscape is SlackChannel.escape: Slack's three characters with a meaning of their own.
func slackEscape(text string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(text)
}

// prefix is String.prefix, by runes.
func prefix(text string, n int) string {
	runes := []rune(text)
	if len(runes) <= n {
		return text
	}
	return string(runes[:n])
}

// marshal is JSONEncoder's one line: no escaping of <, > and &.
func marshal(v any) ([]byte, error) {
	var b strings.Builder
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	if err := e.Encode(v); err != nil {
		return nil, err
	}
	return []byte(strings.TrimSuffix(b.String(), "\n")), nil
}
