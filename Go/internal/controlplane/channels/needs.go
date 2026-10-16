package channels

import "context"

// NeedsChannel is NeedsChannel: a chat app that reaches the person (#1012). It sends a
// Needs You question, hears the tied person's reply to it, and connects in its own way.
type NeedsChannel interface {
	// Start connects, and keeps connected until Stop. What the tied person says goes to
	// heard; how the connection stands goes to status. It does not block.
	Start(heard func(ChannelReply), status func(ChannelStatus))
	Stop()
	// Send sends one waiting question. Its Key names it from now on.
	Send(ctx context.Context, message NeedMessage) error
	// Close ends the question: its buttons go, and saying tells why.
	Close(ctx context.Context, key, saying string)
	// Note adds a note beside the question, which stays open.
	Note(ctx context.Context, key, text string)
}

// NeedMessage is NeedMessage: what a channel draws for one waiting question.
type NeedMessage struct {
	// Key is unique to the question: the host and the need.
	Key string
	// Heading is the project and the conversation: "work · Fix the test".
	Heading  string
	Question string
	Detail   string
	// Options are one button each; none for a question answered in words only.
	Options []Option
	// TakesText tells whether a reply in words answers it.
	TakesText bool
	// AnswerElsewhere is a form this channel cannot draw: answer it in Agents.
	AnswerElsewhere bool
}

// Option is NeedMessage.Option.
type Option struct {
	Value string
	Title string
}

// ReplyKind is ChannelReply's case.
type ReplyKind int

const (
	// Picked is ChannelReply.picked: a button, with the option's value.
	Picked ReplyKind = iota
	// Wrote is ChannelReply.wrote: words in the question's thread.
	Wrote
)

// ChannelReply is ChannelReply: what the tied person said to a question. Value is the
// option's value for Picked, the words for Wrote.
type ChannelReply struct {
	Kind  ReplyKind
	Key   string
	Value string
}

// ChannelStatus is ChannelStatus: how a channel's connection stands. State is
// StatusConnecting, StatusConnected or StatusFailed; Words say what failed.
type ChannelStatus struct {
	State string
	Words string
}
