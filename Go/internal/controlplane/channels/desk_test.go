package channels

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// The desk between needs and a channel: SlackChannelTests' second part.

type fakeChannel struct {
	mu     sync.Mutex
	sent   []NeedMessage
	closed map[string]string
	notes  []string
}

func newFakeChannel() *fakeChannel { return &fakeChannel{closed: map[string]string{}} }

func (f *fakeChannel) Start(func(ChannelReply), func(ChannelStatus)) {}
func (f *fakeChannel) Stop()                                         {}
func (f *fakeChannel) Send(_ context.Context, m NeedMessage) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = append(f.sent, m)
	return nil
}
func (f *fakeChannel) Close(_ context.Context, key, saying string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.closed[key] = saying
}
func (f *fakeChannel) Note(_ context.Context, _, text string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.notes = append(f.notes, text)
}

func (f *fakeChannel) state() ([]NeedMessage, map[string]string, []string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	closed := map[string]string{}
	for k, v := range f.closed {
		closed[k] = v
	}
	return append([]NeedMessage(nil), f.sent...), closed, append([]string(nil), f.notes...)
}

type fakeHost struct {
	mu      sync.Mutex
	pending []ElicitationRequest
	answers []AnswerElicitationRequest
	refuse  error
}

func (h *fakeHost) answered() []AnswerElicitationRequest {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]AnswerElicitationRequest(nil), h.answers...)
}

func (h *fakeHost) hooks() DeskHooks {
	return DeskHooks{
		Pending: func(context.Context, string) ([]ElicitationRequest, error) {
			h.mu.Lock()
			defer h.mu.Unlock()
			return append([]ElicitationRequest(nil), h.pending...), nil
		},
		Answer: func(_ context.Context, _ string, a AnswerElicitationRequest) error {
			h.mu.Lock()
			defer h.mu.Unlock()
			if h.refuse != nil {
				return h.refuse
			}
			h.answers = append(h.answers, a)
			return nil
		},
	}
}

func ptr[T any](v T) *T { return &v }

func form(properties []Property, message *string) ElicitationRequest {
	return ElicitationRequest{ID: NewUUID(), AgentID: NewUUID(), Message: message, Scope: "request",
		AskedAt: RefDate(time.Now()), Mode: ElicitationMode{Form: &ElicitationSchema{Properties: properties}}}
}

var drink = Property{Name: "drink", Title: ptr("Tea or coffee?"), IsRequired: true,
	Kind: PropertyKind{Type: KindString, KindBody: KindBody{Choices: []Choice{{Value: "tea", Title: "Tea"}, {Value: "coffee", Title: "Coffee"}}}}}

var plainText = PropertyKind{Type: KindString}

func offer(r ElicitationRequest) AttentionNeed {
	agent := r.AgentID
	return Offer(Need{ID: NeedID{Elicitation: r.ID}, AgentID: &agent, Folder: "file:///work/", Kind: "elicitation",
		RaisedAt: RefDate(time.Now()), Headline: Headline{H1: "work", H2: "Fix the test", H3: "Asks: Tea or coffee?"}}, true)
}

func deskWith(host *fakeHost) (*Desk, *fakeChannel) {
	desk := NewDesk(host.hooks(), nil)
	channel := newFakeChannel()
	desk.Use(channel)
	return desk, channel
}

func TestAWaitingQuestionGoesOutAndAButtonAnswersItOnItsHost(t *testing.T) {
	ctx := context.Background()
	request := form([]Property{drink}, ptr("Tea or coffee?"))
	host := &fakeHost{pending: []ElicitationRequest{request}}
	desk, channel := deskWith(host)

	desk.Heard(ctx, "h1", offer(request))
	desk.Heard(ctx, "h1", offer(request))
	sent, _, _ := channel.state()
	if len(sent) != 1 {
		t.Fatalf("sent %d", len(sent))
	}
	if sent[0].Heading != "work · Fix the test" || sent[0].Question != "Tea or coffee?" ||
		!reflect.DeepEqual(sent[0].Options, []Option{{"tea", "Tea"}, {"coffee", "Coffee"}}) {
		t.Fatalf("sent %+v", sent[0])
	}
	if sent[0].Key != "h1|elicitation:"+request.ID {
		t.Fatalf("key %s", sent[0].Key)
	}

	desk.HeardReply(ctx, ChannelReply{Kind: Picked, Key: sent[0].Key, Value: "coffee"})
	answers := host.answered()
	if len(answers) != 1 || answers[0].RequestID != request.ID || answers[0].Action != "accept" ||
		!reflect.DeepEqual(answers[0].Content, map[string]any{"drink": "coffee"}) || answers[0].SendID == "" {
		t.Fatalf("answers %+v", answers)
	}
	_, closed, _ := channel.state()
	if closed[sent[0].Key] != "Answered: Coffee" {
		t.Fatalf("closed %v", closed)
	}
	// The host withdraws it next: nothing more is said.
	desk.Heard(ctx, "h1", Withdraw(NeedID{Elicitation: request.ID}))
	if _, closed, _ := channel.state(); len(closed) != 1 {
		t.Fatalf("closed %v", closed)
	}
}

func TestWordsBeforeAButtonGoWithItAsTheNote(t *testing.T) {
	ctx := context.Background()
	note := Property{Name: "drink_custom", Title: ptr("Anything else?"), Kind: plainText}
	request := form([]Property{drink, note}, ptr("Tea or coffee?"))
	host := &fakeHost{pending: []ElicitationRequest{request}}
	desk, channel := deskWith(host)
	desk.Heard(ctx, "h1", offer(request))
	sent, _, _ := channel.state()
	key := sent[0].Key

	desk.HeardReply(ctx, ChannelReply{Kind: Wrote, Key: key, Value: "oat milk"})
	if len(host.answered()) != 0 {
		t.Fatal("words alone answered a choice")
	}
	desk.HeardReply(ctx, ChannelReply{Kind: Picked, Key: key, Value: "tea"})
	if got := host.answered(); len(got) != 1 || !reflect.DeepEqual(got[0].Content, map[string]any{"drink": "tea", "drink_custom": "oat milk"}) {
		t.Fatalf("answers %+v", got)
	}
}

func TestAReplyNamingAnOptionPicksItAndFreeTextAnswersAQuestionInWords(t *testing.T) {
	ctx := context.Background()
	words := Property{Name: "why", Title: ptr("Why did it fail?"), IsRequired: true, Kind: plainText}
	choice, open := form([]Property{drink}, ptr("Tea or coffee?")), form([]Property{words}, nil)
	host := &fakeHost{pending: []ElicitationRequest{choice, open}}
	desk, channel := deskWith(host)
	desk.Heard(ctx, "h1", offer(choice))
	desk.Heard(ctx, "h1", offer(open))
	sent, _, _ := channel.state()
	first, second := sent[0], sent[1]
	if len(second.Options) != 0 || !second.TakesText || second.Question != "Why did it fail?" || second.Detail != "" {
		t.Fatalf("second %+v", second)
	}

	desk.HeardReply(ctx, ChannelReply{Kind: Wrote, Key: first.Key, Value: "neither"})
	if _, _, notes := channel.state(); !reflect.DeepEqual(notes, []string{"Pick one of the buttons."}) {
		t.Fatalf("notes %v", notes)
	}
	desk.HeardReply(ctx, ChannelReply{Kind: Wrote, Key: first.Key, Value: "  TÉA "})
	desk.HeardReply(ctx, ChannelReply{Kind: Wrote, Key: second.Key, Value: "The disk was full."})
	got := host.answered()
	if len(got) != 2 || !reflect.DeepEqual(got[0].Content, map[string]any{"drink": "tea"}) ||
		!reflect.DeepEqual(got[1].Content, map[string]any{"why": "The disk was full."}) {
		t.Fatalf("answers %+v", got)
	}
}

func TestAYesOrNoQuestionTakesButtonsAndWords(t *testing.T) {
	ctx := context.Background()
	sure := Property{Name: "sure", Title: ptr("Sure?"), IsRequired: true, Kind: PropertyKind{Type: KindBoolean}}
	a, b := form([]Property{sure}, nil), form([]Property{sure}, nil)
	host := &fakeHost{pending: []ElicitationRequest{a, b}}
	desk, channel := deskWith(host)
	desk.Heard(ctx, "h1", offer(a))
	desk.Heard(ctx, "h1", offer(b))
	sent, _, _ := channel.state()
	if !reflect.DeepEqual(sent[0].Options, []Option{{"true", "Yes"}, {"false", "No"}}) {
		t.Fatalf("options %+v", sent[0].Options)
	}
	desk.HeardReply(ctx, ChannelReply{Kind: Wrote, Key: sent[0].Key, Value: "maybe"})
	desk.HeardReply(ctx, ChannelReply{Kind: Wrote, Key: sent[0].Key, Value: "Y"})
	desk.HeardReply(ctx, ChannelReply{Kind: Picked, Key: sent[1].Key, Value: "false"})
	got := host.answered()
	if len(got) != 2 || got[0].Content["sure"] != true || got[1].Content["sure"] != false {
		t.Fatalf("answers %+v", got)
	}
	_, closed, notes := channel.state()
	if !reflect.DeepEqual(notes, []string{"Say yes or no, or press a button."}) || closed[sent[1].Key] != "Answered: No" {
		t.Fatalf("notes %v closed %v", notes, closed)
	}
}

func TestAFormSlackCannotDrawSaysToAnswerInAgents(t *testing.T) {
	ctx := context.Background()
	other := Property{Name: "size", Title: ptr("Size?"), IsRequired: true,
		Kind: PropertyKind{Type: KindInteger, KindBody: KindBody{Minimum: ptr(1.0), Maximum: ptr(3.0)}}}
	request := form([]Property{drink, other}, ptr("Two things"))
	host := &fakeHost{pending: []ElicitationRequest{request}}
	desk, channel := deskWith(host)
	desk.Heard(ctx, "h1", offer(request))
	sent, _, _ := channel.state()
	if !sent[0].AnswerElsewhere || len(sent[0].Options) != 0 || sent[0].TakesText || sent[0].Question != "Two things" {
		t.Fatalf("sent %+v", sent[0])
	}
	desk.HeardReply(ctx, ChannelReply{Kind: Wrote, Key: sent[0].Key, Value: "tea"})
	if _, _, notes := channel.state(); !reflect.DeepEqual(notes, []string{"This one can only be answered in Agents."}) {
		t.Fatalf("notes %v", notes)
	}
	if len(host.answered()) != 0 {
		t.Fatal("answered")
	}
}

func TestAWithdrawnQuestionClosesAndOtherNeedsAreNotSent(t *testing.T) {
	ctx := context.Background()
	request := form([]Property{drink}, ptr("Tea or coffee?"))
	desk, channel := deskWith(&fakeHost{pending: []ElicitationRequest{request}})
	permission := Offer(Need{ID: NeedID{Permission: NewUUID()}, AgentID: ptr(NewUUID()), Folder: "file:///work/",
		Kind: "permission", RaisedAt: RefDate(time.Now()), Headline: Headline{"work", "x", "may run a command"}}, true)
	desk.Heard(ctx, "h1", permission)
	if sent, _, _ := channel.state(); len(sent) != 0 {
		t.Fatal("a permission was sent")
	}
	desk.Heard(ctx, "h1", offer(request))
	sent, _, _ := channel.state()
	key := sent[0].Key
	desk.Heard(ctx, "h1", Withdraw(NeedID{Elicitation: request.ID}))
	if _, closed, _ := channel.state(); !strings.HasPrefix(closed[key], "No longer waiting") {
		t.Fatalf("closed %v", closed)
	}
	desk.HeardReply(ctx, ChannelReply{Kind: Picked, Key: key, Value: "tea"})
	if _, closed, _ := channel.state(); len(closed) != 1 {
		t.Fatalf("closed %v", closed)
	}
}

func TestAnAnswerTheHostRefusesIsSaidAndTheQuestionStaysOpen(t *testing.T) {
	ctx := context.Background()
	request := form([]Property{drink}, ptr("Tea or coffee?"))
	host := &fakeHost{pending: []ElicitationRequest{request},
		refuse: &RPCError{Code: CodeInvalidParams, Message: "That answer doesn’t fit."}}
	desk, channel := deskWith(host)
	desk.Heard(ctx, "h1", offer(request))
	sent, _, _ := channel.state()
	key := sent[0].Key
	desk.HeardReply(ctx, ChannelReply{Kind: Picked, Key: key, Value: "tea"})
	if _, _, notes := channel.state(); !reflect.DeepEqual(notes, []string{"That didn't go: That answer doesn’t fit."}) {
		t.Fatalf("notes %v", notes)
	}
	if keys := desk.OpenKeys(); !reflect.DeepEqual(keys, []string{key}) {
		t.Fatalf("open %v", keys)
	}
	host.mu.Lock()
	host.refuse = errors.New("gone")
	host.mu.Unlock()
	desk.HeardReply(ctx, ChannelReply{Kind: Picked, Key: key, Value: "tea"})
	if _, _, notes := channel.state(); notes[1] != "That didn't go: the host didn't answer. Try again, or answer in Agents." {
		t.Fatalf("notes %v", notes)
	}
}

func TestPostedNeedsAreHandledInOrder(t *testing.T) {
	request := form([]Property{drink}, ptr("Tea or coffee?"))
	desk, channel := deskWith(&fakeHost{pending: []ElicitationRequest{request}})
	desk.Post("h1", offer(request))
	desk.Post("h1", Withdraw(NeedID{Elicitation: request.ID}))
	eventually(t, "sent and closed", func() bool {
		sent, closed, _ := channel.state()
		return len(sent) == 1 && len(closed) == 1
	})
}
