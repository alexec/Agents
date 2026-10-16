package channels

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"unicode"

	"github.com/alexec/agents/Go/internal/safe"
)

// DeskHooks is ChannelDesk.Hooks: how the desk reaches a host.
type DeskHooks struct {
	// Pending is elicitations/pending on a host.
	Pending func(ctx context.Context, host string) ([]ElicitationRequest, error)
	// Answer is elicitations/answer on a host. A refusal the host gave is an *RPCError,
	// so its words reach the person.
	Answer func(ctx context.Context, host string, answer AnswerElicitationRequest) error
}

// shapeKind is ChannelDesk.Shape's case.
type shapeKind int

const (
	shapeChoice shapeKind = iota
	shapeText
	shapeBoolean
	shapeElsewhere
)

// shape is ChannelDesk.Shape: how a question is answered from a channel.
type shape struct {
	kind     shapeKind
	property string
	choices  []Choice
	// note is the name of the note property beside a choice, or nil.
	note *string
}

// openQuestion is ChannelDesk.Open.
type openQuestion struct {
	host    string
	request string
	shape   shape
	// note is words written before a button was pressed.
	note *string
}

type posted struct {
	host string
	need AttentionNeed
}

// Desk is ChannelDesk: between the hosts' needs and a channel. A waiting question a host
// offers goes out, and what the person says back answers it on that host. Only question
// cards (elicitations) go out.
type Desk struct {
	hooks DeskHooks
	log   func(string)

	mu      sync.Mutex
	channel NeedsChannel
	open    map[string]*openQuestion

	inboxMu  sync.Mutex
	inbox    []posted
	draining bool
}

// NewDesk is ChannelDesk.init. log may be nil.
func NewDesk(hooks DeskHooks, log func(string)) *Desk {
	if log == nil {
		log = func(string) {}
	}
	return &Desk{hooks: hooks, log: log, open: map[string]*openQuestion{}}
}

// Post is ChannelDesk.post: a host's attention/need, handled in the order heard and apart
// from the host's uplink, since reading the question asks that host. It does not block.
func (d *Desk) Post(host string, need AttentionNeed) {
	d.inboxMu.Lock()
	d.inbox = append(d.inbox, posted{host, need})
	start := !d.draining
	d.draining = true
	d.inboxMu.Unlock()
	if start {
		safe.Go("channels desk", d.drain)
	}
}

func (d *Desk) drain() {
	for {
		d.inboxMu.Lock()
		if len(d.inbox) == 0 {
			d.draining = false
			d.inboxMu.Unlock()
			return
		}
		next := d.inbox[0]
		d.inbox = d.inbox[1:]
		d.inboxMu.Unlock()
		safe.Catch("channels desk", func() { d.Heard(context.Background(), next.host, next.need) })
	}
}

// Use is ChannelDesk.use: the channel questions go to from now on, or nil for none. What
// was open on the old one is forgotten.
func (d *Desk) Use(channel NeedsChannel) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.channel = channel
	d.open = map[string]*openQuestion{}
}

// Key is ChannelDesk.key: "<host>|<need token>".
func Key(host string, need NeedID) string { return host + "|" + need.Token() }

// Heard is ChannelDesk.heard(_:_:): a host's attention/need.
func (d *Desk) Heard(ctx context.Context, host string, need AttentionNeed) {
	if need.Withdraw != nil {
		key := Key(host, *need.Withdraw)
		d.mu.Lock()
		_, ok := d.open[key]
		delete(d.open, key)
		channel := d.channel
		d.mu.Unlock()
		if ok && channel != nil {
			channel.Close(ctx, key, "No longer waiting: answered, or seen in Agents.")
		}
		return
	}
	d.mu.Lock()
	channel := d.channel
	d.mu.Unlock()
	if channel == nil || need.Need == nil || need.Need.ID.Elicitation == "" {
		return
	}
	offered := need.Need
	id := offered.ID.Elicitation
	key := Key(host, offered.ID)
	// A host whose uplink came back offers every live need again.
	if d.isOpen(key) {
		return
	}
	pending, err := d.hooks.Pending(ctx, host)
	if err != nil {
		d.log(fmt.Sprintf("channels: could not read %s's question: %v", host, err))
		return
	}
	var request *ElicitationRequest
	for i := range pending {
		if strings.EqualFold(pending[i].ID, id) {
			request = &pending[i]
			break
		}
	}
	if request == nil {
		d.log("channels: " + key + " was answered before it could be sent")
		return
	}
	msg, how := message(key, *request, offered.Headline)
	d.mu.Lock()
	// Asked again while that was read.
	if _, ok := d.open[key]; ok {
		d.mu.Unlock()
		return
	}
	d.open[key] = &openQuestion{host: host, request: request.ID, shape: how}
	d.mu.Unlock()
	if err := channel.Send(ctx, msg); err != nil {
		d.mu.Lock()
		delete(d.open, key)
		d.mu.Unlock()
		d.log(fmt.Sprintf("channels: could not send %s: %v", key, err))
		return
	}
	d.log("channels: sent " + key)
}

func (d *Desk) isOpen(key string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	_, ok := d.open[key]
	return ok
}

// message is ChannelDesk.message: the question as a channel draws it, and how it is answered.
func message(key string, request ElicitationRequest, headline Headline) (NeedMessage, shape) {
	var parts []string
	for _, h := range []string{headline.H1, headline.H2} {
		if h != "" {
			parts = append(parts, h)
		}
	}
	heading := strings.Join(parts, " · ")
	schema := request.Mode.Form
	if schema == nil || len(schema.Pages()) != 1 || len(schema.Properties) == 0 {
		question := request.Title()
		if request.Message != nil {
			question = *request.Message
		}
		return NeedMessage{Key: key, Heading: heading, Question: question, AnswerElsewhere: true}, shape{kind: shapeElsewhere}
	}
	first := schema.Properties[0]
	question := "The agent asks"
	switch {
	case request.Message != nil:
		question = *request.Message
	case first.Title != nil:
		question = *first.Title
	case schema.Title != nil:
		question = *schema.Title
	}
	detail := ""
	if first.Description != nil {
		detail = *first.Description
	} else if first.Title != nil && *first.Title != question {
		detail = *first.Title
	}
	var note *string
	if len(schema.Properties) > 1 {
		name := schema.Properties[1].Name
		note = &name
	}
	m := NeedMessage{Key: key, Heading: heading, Question: question, Detail: detail, TakesText: true}
	switch {
	case first.Kind.Type == KindString && len(first.Kind.Choices) > 0:
		for _, c := range first.Kind.Choices {
			m.Options = append(m.Options, Option{Value: c.Value, Title: c.Title})
		}
		return m, shape{kind: shapeChoice, property: first.Name, choices: first.Kind.Choices, note: note}
	case first.Kind.Type == KindString && note == nil:
		return m, shape{kind: shapeText, property: first.Name}
	case first.Kind.Type == KindBoolean && note == nil:
		m.Options = []Option{{Value: "true", Title: "Yes"}, {Value: "false", Title: "No"}}
		return m, shape{kind: shapeBoolean, property: first.Name}
	}
	m.TakesText = false
	m.AnswerElsewhere = true
	return m, shape{kind: shapeElsewhere}
}

// HeardReply is ChannelDesk.heard(_:) for a ChannelReply: the tied person said something
// to a question.
func (d *Desk) HeardReply(ctx context.Context, reply ChannelReply) {
	d.mu.Lock()
	channel := d.channel
	found, ok := d.open[reply.Key]
	var question openQuestion
	if ok {
		question = *found
	}
	d.mu.Unlock()
	if channel == nil || !ok {
		return
	}
	content := map[string]any{}
	said := ""
	s := question.shape
	words := strings.TrimSpace(reply.Value)
	switch {
	case s.kind == shapeElsewhere:
		channel.Note(ctx, reply.Key, "This one can only be answered in Agents.")
		return
	case s.kind == shapeChoice && reply.Kind == Picked:
		choice := findChoice(s.choices, func(c Choice) bool { return c.Value == reply.Value })
		if choice == nil {
			return
		}
		content[s.property] = reply.Value
		if s.note != nil && question.note != nil {
			content[*s.note] = *question.note
		}
		said = choice.Title
	case s.kind == shapeChoice && reply.Kind == Wrote:
		if choice := findChoice(s.choices, func(c Choice) bool { return same(c.Title, words) || same(c.Value, words) }); choice != nil {
			content[s.property] = choice.Value
			said = choice.Title
		} else if s.note != nil {
			d.mu.Lock()
			if q, ok := d.open[reply.Key]; ok {
				q.note = &words
			}
			d.mu.Unlock()
			channel.Note(ctx, reply.Key, "Noted. Now pick one of the buttons, and your words go with it.")
			return
		} else {
			channel.Note(ctx, reply.Key, "Pick one of the buttons.")
			return
		}
	case s.kind == shapeText && reply.Kind == Wrote:
		if words == "" {
			return
		}
		content[s.property] = words
		said = words
	case s.kind == shapeBoolean && reply.Kind == Picked:
		content[s.property] = reply.Value == "true"
		said = "No"
		if reply.Value == "true" {
			said = "Yes"
		}
	case s.kind == shapeBoolean && reply.Kind == Wrote:
		switch {
		case same(words, "yes") || same(words, "y"):
			content[s.property] = true
			said = "Yes"
		case same(words, "no") || same(words, "n"):
			content[s.property] = false
			said = "No"
		default:
			channel.Note(ctx, reply.Key, "Say yes or no, or press a button.")
			return
		}
	default:
		return
	}
	err := d.hooks.Answer(ctx, question.host, AnswerElicitationRequest{
		RequestID: question.request, Action: "accept", Content: content, SendID: NewUUID()})
	if err != nil {
		var refused *RPCError
		if errors.As(err, &refused) {
			channel.Note(ctx, reply.Key, "That didn't go: "+refused.Message)
		} else {
			channel.Note(ctx, reply.Key, "That didn't go: the host didn't answer. Try again, or answer in Agents.")
		}
		return
	}
	d.mu.Lock()
	delete(d.open, reply.Key)
	d.mu.Unlock()
	channel.Close(ctx, reply.Key, "Answered: "+said)
	d.log("channels: answered " + reply.Key)
}

func findChoice(choices []Choice, match func(Choice) bool) *Choice {
	for i := range choices {
		if match(choices[i]) {
			return &choices[i]
		}
	}
	return nil
}

// OpenKeys is ChannelDesk.openKeys: the questions out now, for tests.
func (d *Desk) OpenKeys() []string {
	d.mu.Lock()
	defer d.mu.Unlock()
	keys := make([]string, 0, len(d.open))
	for k := range d.open {
		keys = append(keys, k)
	}
	return keys
}

// same is ChannelDesk.same: equal with no regard to case or accents.
func same(a, b string) bool { return strings.EqualFold(plain(a), plain(b)) }

// plain takes the accents off the Latin letters that carry them most often.
func plain(text string) string {
	return strings.Map(func(r rune) rune {
		if r < 0xC0 || !unicode.IsLetter(r) {
			return r
		}
		if base, ok := accents[r]; ok {
			return base
		}
		return r
	}, text)
}

var accents = func() map[rune]rune {
	m := map[rune]rune{}
	for base, all := range map[rune]string{
		'a': "àáâãäåāăą", 'A': "ÀÁÂÃÄÅĀĂĄ", 'c': "çćĉċč", 'C': "ÇĆĈĊČ", 'd': "ď", 'D': "Ď",
		'e': "èéêëēĕėęě", 'E': "ÈÉÊËĒĔĖĘĚ", 'g': "ĝğġģ", 'G': "ĜĞĠĢ", 'h': "ĥ", 'H': "Ĥ",
		'i': "ìíîïĩīĭįı", 'I': "ÌÍÎÏĨĪĬĮİ", 'j': "ĵ", 'J': "Ĵ", 'k': "ķ", 'K': "Ķ",
		'l': "ĺļľ", 'L': "ĹĻĽ", 'n': "ñńņňŉ", 'N': "ÑŃŅŇ", 'o': "òóôõöōŏő", 'O': "ÒÓÔÕÖŌŎŐ",
		'r': "ŕŗř", 'R': "ŔŖŘ", 's': "śŝşš", 'S': "ŚŜŞŠ", 't': "ţť", 'T': "ŢŤ",
		'u': "ùúûüũūŭůűų", 'U': "ÙÚÛÜŨŪŬŮŰŲ", 'w': "ŵ", 'W': "Ŵ", 'y': "ýÿŷ", 'Y': "ÝŸŶ",
		'z': "źżž", 'Z': "ŹŻŽ",
	} {
		for _, r := range all {
			m[r] = base
		}
	}
	return m
}()
