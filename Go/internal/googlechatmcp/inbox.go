package googlechatmcp

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"log/slog"
	"strings"
	"sync"
	"time"

	chat "google.golang.org/api/chat/v1"
)

// The inbox (#1016): what the app was sent, pulled from its Pub/Sub subscription by one loop
// and kept in order, so that every events/poll, each with its own cursor, reads the same
// list. Pub/Sub is a queue, not a log: a message is acknowledged once it is in the inbox, and
// the inbox keeps the newest maxKept for keptFor. The loop starts at the first poll, or the
// first read of a conversation, so a server nobody listens to or reads leaves the subscription
// alone. The inbox is also the bounded store that read_messages pages when the Chat API does
// not let the app read a space (#4342): what people sent the app, and what the app posted.

const (
	maxKept  = 1000
	keptFor  = 24 * time.Hour
	pullSize = 100
)

// Kind is what happened.
type Kind string

const (
	// Message: a person wrote to the app, in a direct message or with an @mention.
	Message Kind = "message"
	// Answer: a person pressed an option on a question the app asked (ask_question).
	Answer Kind = "answer"
	// Sent: the app posted a message (send_message, ask_question). It is no event: it is kept
	// so that a conversation read from the inbox has both sides.
	Sent Kind = "sent"
)

// Person is who did it, as the Chat API names them.
type Person struct {
	Name        string `json:"name"`
	DisplayName string `json:"displayName"`
	Email       string `json:"email"`
	Type        string `json:"type"`
}

// Item is one thing that happened, in the inbox's order.
type Item struct {
	Seq  uint64
	ID   string
	Kind Kind
	At   time.Time
	// Space is the space's name (spaces/…), SpaceType DIRECT_MESSAGE, GROUP_CHAT or SPACE.
	Space, SpaceType, SpaceName string
	// Thread and Message are the names of the thread and the message: for an Answer, the
	// question's message.
	Thread, Message string
	// Text is what the person wrote, without the app's @mention.
	Text string
	// Question, Answer and Label are an Answer's: the question's id, the option's id and words.
	Question, Answer, Label string
	From                    Person
}

// event is the part of a Chat app's interaction event that the server reads.
type event struct {
	Type      string `json:"type"`
	EventTime string `json:"eventTime"`
	Space     struct {
		Name        string `json:"name"`
		Type        string `json:"type"`
		SpaceType   string `json:"spaceType"`
		DisplayName string `json:"displayName"`
	} `json:"space"`
	Message struct {
		Name         string `json:"name"`
		Text         string `json:"text"`
		ArgumentText string `json:"argumentText"`
		Thread       struct {
			Name string `json:"name"`
		} `json:"thread"`
	} `json:"message"`
	User   Person `json:"user"`
	Action struct {
		ActionMethodName string `json:"actionMethodName"`
		Parameters       []struct {
			Key   string `json:"key"`
			Value string `json:"value"`
		} `json:"parameters"`
	} `json:"action"`
	Common struct {
		InvokedFunction string            `json:"invokedFunction"`
		Parameters      map[string]string `json:"parameters"`
	} `json:"common"`
}

// answerFunction is the action an option of ask_question's card names.
const answerFunction = "agents.answer"

// parse is one Pub/Sub message as an Item: false for what the server does not raise (the app
// added to or removed from a space, a bot, an action that is not an answer).
func parse(r Received) (Item, bool) {
	var e event
	if json.Unmarshal(r.Data, &e) != nil || !strings.EqualFold(e.User.Type, "HUMAN") || e.User.Name == "" || e.Space.Name == "" {
		return Item{}, false
	}
	it := Item{ID: r.ID, At: r.Published, Space: e.Space.Name, SpaceName: e.Space.DisplayName, SpaceType: spaceType(e.Space.SpaceType, e.Space.Type),
		Thread: e.Message.Thread.Name, Message: e.Message.Name, From: e.User}
	if t, err := time.Parse(time.RFC3339Nano, e.EventTime); err == nil {
		it.At = t
	}
	if it.At.IsZero() {
		it.At = time.Now()
	}
	switch e.Type {
	case "MESSAGE":
		it.Kind = Message
		it.Text = strings.TrimSpace(e.Message.ArgumentText)
		if it.Text == "" {
			it.Text = strings.TrimSpace(e.Message.Text)
		}
		return it, it.Text != ""
	case "CARD_CLICKED":
		params := map[string]string{}
		for k, v := range e.Common.Parameters {
			params[k] = v
		}
		for _, p := range e.Action.Parameters {
			params[p.Key] = p.Value
		}
		function := e.Common.InvokedFunction
		if function == "" {
			function = e.Action.ActionMethodName
		}
		if function != answerFunction || params["question"] == "" || params["answer"] == "" {
			return Item{}, false
		}
		it.Kind, it.Question, it.Answer, it.Label = Answer, params["question"], params["answer"], params["label"]
		return it, true
	}
	return Item{}, false
}

// spaceType is the space's type in the Chat API's newer words.
func spaceType(newer, older string) string {
	if newer != "" {
		return newer
	}
	switch older {
	case "DM":
		return "DIRECT_MESSAGE"
	case "ROOM":
		return "SPACE"
	}
	return older
}

func decodeBase64(s string) ([]byte, error) {
	if b, err := base64.StdEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	return base64.RawURLEncoding.DecodeString(strings.TrimRight(s, "="))
}

// Inbox pulls from Google and keeps what it pulled.
type Inbox struct {
	Google *Google
	Logger *slog.Logger
	// Answered is told of each answer as it comes, to mark the question's card.
	Answered func(context.Context, Item)

	mu      sync.Mutex
	items   []Item
	seq     uint64
	started bool
	failure error
	boot    string
}

// NewInbox is an inbox; boot tells a cursor of this run from one of an earlier run.
func NewInbox(g *Google, logger *slog.Logger) *Inbox {
	return &Inbox{Google: g, Logger: logger, boot: time.Now().UTC().Format("20060102T150405.000000000")}
}

// Start runs the loop that pulls, once; it ends with ctx.
func (in *Inbox) Start(ctx context.Context) {
	in.mu.Lock()
	if in.started {
		in.mu.Unlock()
		return
	}
	in.started = true
	in.mu.Unlock()
	go in.loop(ctx)
}

func (in *Inbox) loop(ctx context.Context) {
	wait := time.Second
	for ctx.Err() == nil {
		got, err := in.Google.Pull(ctx, pullSize)
		if err == nil {
			err = in.keep(ctx, got)
		}
		in.mu.Lock()
		in.failure = err
		in.mu.Unlock()
		if err == nil {
			wait = time.Second
			continue
		}
		if ctx.Err() == nil && in.Logger != nil {
			in.Logger.Warn("googlechat-mcp: pull", "err", err)
		}
		select {
		case <-ctx.Done():
		case <-time.After(wait):
		}
		wait = min(2*wait, time.Minute)
	}
}

// keep puts what was pulled in the inbox, then acknowledges all of it.
func (in *Inbox) keep(ctx context.Context, got []Received) error {
	if len(got) == 0 {
		return nil
	}
	acks := make([]string, 0, len(got))
	answers := []Item{}
	in.mu.Lock()
	for _, r := range got {
		acks = append(acks, r.AckID)
		it, ok := parse(r)
		if !ok || in.has(r.ID) || it.Kind == Answer && in.answered(it.Question) {
			continue
		}
		in.seq++
		it.Seq = in.seq
		in.items = append(in.items, it)
		if it.Kind == Answer {
			answers = append(answers, it)
		}
	}
	in.trim(time.Now())
	in.mu.Unlock()
	for _, a := range answers {
		if in.Answered != nil {
			in.Answered(ctx, a)
		}
	}
	return in.Google.Ack(ctx, acks)
}

// has is true when the inbox holds the Pub/Sub message already (sent again before its ack).
func (in *Inbox) has(id string) bool {
	for i := len(in.items) - 1; i >= 0 && i >= len(in.items)-pullSize*2; i-- {
		if in.items[i].ID == id {
			return true
		}
	}
	return false
}

// answered is true when the inbox holds an answer to the question already: only the first
// press counts, as the card loses its options once it is marked.
func (in *Inbox) answered(question string) bool {
	for _, it := range in.items {
		if it.Kind == Answer && it.Question == question {
			return true
		}
	}
	return false
}

func (in *Inbox) trim(now time.Time) {
	drop := max(0, len(in.items)-maxKept)
	for drop < len(in.items) && now.Sub(in.items[drop].At) > keptFor {
		drop++
	}
	if drop > 0 {
		in.items = append([]Item(nil), in.items[drop:]...)
	}
}

// Head is this run's boot and the newest item's number.
func (in *Inbox) Head() (string, uint64) {
	in.mu.Lock()
	defer in.mu.Unlock()
	return in.boot, in.seq
}

// After is the items after seq, at most limit, whether there are more, and the last pull's
// failure.
func (in *Inbox) After(seq uint64, limit int) ([]Item, bool, error) {
	in.mu.Lock()
	defer in.mu.Unlock()
	out := []Item{}
	for _, it := range in.items {
		if it.Seq <= seq {
			continue
		}
		if len(out) == limit {
			return out, true, in.failure
		}
		out = append(out, it)
	}
	return out, false, in.failure
}

// Posted keeps a message the app posted, in the space and thread it went to.
func (in *Inbox) Posted(space, thread string, m *chat.Message, text string) {
	if m == nil || m.Name == "" {
		return
	}
	it := Item{ID: m.Name, Kind: Sent, At: time.Now(), Space: space, Thread: threadOf(m, thread), Message: m.Name, Text: text,
		From: Person{Name: "users/app", Type: "BOT"}}
	if m.Sender != nil && m.Sender.Name != "" {
		it.From = Person{Name: m.Sender.Name, DisplayName: m.Sender.DisplayName, Type: m.Sender.Type}
	}
	if t, err := time.Parse(time.RFC3339Nano, m.CreateTime); err == nil {
		it.At = t
	}
	in.mu.Lock()
	defer in.mu.Unlock()
	in.seq++
	it.Seq = in.seq
	in.items = append(in.items, it)
	in.trim(time.Now())
}

// Conversation is the messages kept of a space, or of one thread of it, the newest first: at
// most limit, older than before when it is not 0, and whether there are older ones.
func (in *Inbox) Conversation(space, thread string, before uint64, limit int) ([]Item, bool) {
	in.mu.Lock()
	defer in.mu.Unlock()
	out := []Item{}
	for i := len(in.items) - 1; i >= 0; i-- {
		it := in.items[i]
		if before != 0 && it.Seq >= before || it.Kind == Answer || it.Space != space || thread != "" && it.Thread != thread {
			continue
		}
		if len(out) == limit {
			return out, true
		}
		out = append(out, it)
	}
	return out, false
}

// Latest is the newest message kept of a space, and false when none is.
func (in *Inbox) Latest(space string) (Item, bool) {
	in.mu.Lock()
	defer in.mu.Unlock()
	for i := len(in.items) - 1; i >= 0; i-- {
		if it := in.items[i]; it.Space == space && it.Kind != Answer {
			return it, true
		}
	}
	return Item{}, false
}

// Person is the newest person who wrote in a space, for a direct message's title.
func (in *Inbox) Person(space string) (Person, bool) {
	in.mu.Lock()
	defer in.mu.Unlock()
	for i := len(in.items) - 1; i >= 0; i-- {
		if it := in.items[i]; it.Space == space && it.Kind != Sent && it.From.DisplayName != "" {
			return it.From, true
		}
	}
	return Person{}, false
}

// Boot tells a cursor of this run from one of an earlier run.
func (in *Inbox) Boot() string { return in.boot }

// Failure is the last pull's failure, nil when it worked.
func (in *Inbox) Failure() error {
	in.mu.Lock()
	defer in.mu.Unlock()
	return in.failure
}
