package googlechatmcp

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	chat "google.golang.org/api/chat/v1"
)

// The Google Chat server's tools (#1016): list the spaces the app is in, post a message as
// the app, and ask a question with its options as buttons, whose answer comes back as the
// event question.answered. The app can post only where a person added it, so a space it is not
// in cannot be reached. list_conversations and read_messages are the messaging contract's
// (messaging.go, #4342); what the app posts is kept in the inbox for them.

const (
	maxText    = 4000
	maxOptions = 6
	maxLabel   = 60
)

var (
	spaceRule  = regexp.MustCompile(`^spaces/[A-Za-z0-9_-]{1,64}$`)
	threadRule = regexp.MustCompile(`^spaces/[A-Za-z0-9_-]{1,64}/threads/[A-Za-z0-9_.-]{1,128}$`)
	idRule     = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,64}$`)
)

type spacesArgs struct {
	Limit int `json:"limit,omitempty" jsonschema:"at most this many: 50 when left out, 200 at most"`
}

type sendArgs struct {
	Space  string `json:"space" jsonschema:"the space, as list_spaces or an event names it: spaces/AAAA…"`
	Text   string `json:"text" jsonschema:"the message, at most 4000 characters; *bold*, _italic_ and links as Google Chat writes them"`
	Thread string `json:"thread,omitempty" jsonschema:"the thread to answer in, as an event names it: spaces/…/threads/…; a new thread when left out"`
}

type choice struct {
	ID    string `json:"id" jsonschema:"the option's id, given back as answer: letters, digits, _ . : -"`
	Label string `json:"label" jsonschema:"the button's words, at most 60 characters"`
}

type askArgs struct {
	Space    string   `json:"space" jsonschema:"the space to ask in"`
	Question string   `json:"question" jsonschema:"the question, at most 4000 characters"`
	Options  []choice `json:"options" jsonschema:"two to six options, one button each"`
	Thread   string   `json:"thread,omitempty" jsonschema:"the thread to ask in; a new thread when left out"`
	ID       string   `json:"id,omitempty" jsonschema:"the question's id, given back in question.answered, such as the session it is for; made up when left out"`
	Title    string   `json:"title,omitempty" jsonschema:"a line above the question, such as the asking session's title"`
}

// structured is a tool's answer: the data, and the same as JSON text for a client that
// reads only text.
func structured(data map[string]any) *mcp.CallToolResult {
	text, _ := json.Marshal(data)
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(text)}}, StructuredContent: data}
}

func failed(err error) *mcp.CallToolResult {
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: err.Error()}}, IsError: true}
}

func tool[In any](server *mcp.Server, t *mcp.Tool, f func(context.Context, In) (*mcp.CallToolResult, error)) {
	mcp.AddTool(server, t, func(ctx context.Context, _ *mcp.CallToolRequest, in In) (*mcp.CallToolResult, any, error) {
		r, err := f(ctx, in)
		if err != nil {
			return failed(err), nil, nil
		}
		return r, nil, nil
	})
}

func checkPlace(space, thread string) (string, string, error) {
	space, thread = strings.TrimSpace(space), strings.TrimSpace(thread)
	if !spaceRule.MatchString(space) {
		return "", "", fmt.Errorf("space must be a space's name, such as spaces/AAAAbcd, as list_spaces gives it")
	}
	if thread != "" && (!threadRule.MatchString(thread) || !strings.HasPrefix(thread, space+"/")) {
		return "", "", fmt.Errorf("thread must be a thread of that space: %s/threads/…", space)
	}
	return space, thread, nil
}

func checkText(name, text string) (string, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return "", fmt.Errorf("%s is empty", name)
	}
	if utf8.RuneCountInString(text) > maxText {
		return "", fmt.Errorf("%s is longer than %d characters", name, maxText)
	}
	return text, nil
}

// AddTools puts the tools on server; e's inbox keeps what they post.
func AddTools(server *mcp.Server, e *Events) {
	g := e.Inbox.Google
	readOnly := &mcp.ToolAnnotations{ReadOnlyHint: true}
	notDestructive := false
	openWorld := true
	posts := &mcp.ToolAnnotations{DestructiveHint: &notDestructive, OpenWorldHint: &openWorld}

	tool(server, &mcp.Tool{Name: "list_spaces", Title: "List spaces",
		Description: "The spaces, group chats and direct messages the Chat app is in: each one's name (spaces/…), its title and its type. The app can post only in these.",
		Annotations: readOnly},
		func(ctx context.Context, in spacesArgs) (*mcp.CallToolResult, error) {
			limit := in.Limit
			if limit <= 0 {
				limit = 50
			}
			spaces, err := g.Spaces(ctx, min(limit, 200))
			if err != nil {
				return nil, err
			}
			list := make([]any, len(spaces))
			for i, s := range spaces {
				list[i] = map[string]any{"name": s.Name, "title": s.DisplayName, "type": s.Type}
			}
			return structured(map[string]any{"spaces": list}), nil
		})

	tool(server, &mcp.Tool{Name: "send_message", Title: "Send a message",
		Description: "Posts a message as the Chat app in a space it is in, in a thread when one is given (answer a message.received in its thread). " +
			"Everyone in the space sees it: write only what they may read.",
		Annotations: posts},
		func(ctx context.Context, in sendArgs) (*mcp.CallToolResult, error) {
			space, thread, err := checkPlace(in.Space, in.Thread)
			if err != nil {
				return nil, err
			}
			text, err := checkText("text", in.Text)
			if err != nil {
				return nil, err
			}
			posted, err := g.Post(ctx, space, thread, &chat.Message{Text: text})
			if err != nil {
				return nil, err
			}
			e.Inbox.Posted(space, thread, posted, text)
			return structured(map[string]any{"message": posted.Name, "thread": threadOf(posted, thread)}), nil
		})

	tool(server, &mcp.Tool{Name: "ask_question", Title: "Ask a question",
		Description: "Posts a question as the Chat app, with a button for each option. The first press comes back as the event question.answered, with the question's id " +
			"and the option's id; the card then says who answered and what. Use it to bring an agent's question to a person who is not at the app.",
		Annotations: posts},
		func(ctx context.Context, in askArgs) (*mcp.CallToolResult, error) {
			space, thread, err := checkPlace(in.Space, in.Thread)
			if err != nil {
				return nil, err
			}
			question, err := checkText("question", in.Question)
			if err != nil {
				return nil, err
			}
			if len(in.Options) < 2 || len(in.Options) > maxOptions {
				return nil, fmt.Errorf("options must be two to %d", maxOptions)
			}
			seen := map[string]bool{}
			for i, o := range in.Options {
				o.ID, o.Label = strings.TrimSpace(o.ID), strings.TrimSpace(o.Label)
				if !idRule.MatchString(o.ID) || seen[o.ID] {
					return nil, fmt.Errorf("option %d: id must be unique, of letters, digits, _ . : -", i+1)
				}
				if o.Label == "" || utf8.RuneCountInString(o.Label) > maxLabel {
					return nil, fmt.Errorf("option %d: label must be 1 to %d characters", i+1, maxLabel)
				}
				seen[o.ID] = true
				in.Options[i] = o
			}
			id := strings.TrimSpace(in.ID)
			if id == "" {
				id = newID()
			} else if !idRule.MatchString(id) {
				return nil, fmt.Errorf("id must be 1 to 64 letters, digits, _ . : -")
			}
			title := strings.TrimSpace(in.Title)
			if utf8.RuneCountInString(title) > 200 {
				title = string([]rune(title)[:200])
			}
			posted, err := g.Post(ctx, space, thread, &chat.Message{FallbackText: question, CardsV2: []*chat.CardWithId{questionCard(id, title, question, in.Options)}})
			if err != nil {
				return nil, err
			}
			e.Inbox.Posted(space, thread, posted, question)
			return structured(map[string]any{"question": id, "message": posted.Name, "thread": threadOf(posted, thread)}), nil
		})

	addMessagingTools(server, e)
}

func threadOf(m *chat.Message, asked string) string {
	if m != nil && m.Thread != nil && m.Thread.Name != "" {
		return m.Thread.Name
	}
	return asked
}

func newID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return "q-" + hex.EncodeToString(b)
}

// questionCard is the question with a button per option; a press calls answerFunction with
// the question, the option and its words.
func questionCard(id, title, question string, options []choice) *chat.CardWithId {
	buttons := make([]*chat.GoogleAppsCardV1Button, len(options))
	for i, o := range options {
		buttons[i] = &chat.GoogleAppsCardV1Button{Text: o.Label, OnClick: &chat.GoogleAppsCardV1OnClick{Action: &chat.GoogleAppsCardV1Action{
			Function: answerFunction,
			Parameters: []*chat.GoogleAppsCardV1ActionParameter{
				{Key: "question", Value: id}, {Key: "answer", Value: o.ID}, {Key: "label", Value: o.Label},
			},
		}}}
	}
	card := &chat.GoogleAppsCardV1Card{Sections: []*chat.GoogleAppsCardV1Section{{Widgets: []*chat.GoogleAppsCardV1Widget{
		{TextParagraph: &chat.GoogleAppsCardV1TextParagraph{Text: escape(question)}},
		{ButtonList: &chat.GoogleAppsCardV1ButtonList{Buttons: buttons}},
	}}}}
	if title != "" {
		card.Header = &chat.GoogleAppsCardV1CardHeader{Title: title}
	}
	return &chat.CardWithId{CardId: "question-" + id, Card: card}
}

// answeredCard is the question once answered: no buttons, and who chose what.
func answeredCard(it Item) *chat.CardWithId {
	who := it.From.DisplayName
	if who == "" {
		who = "Someone"
	}
	return &chat.CardWithId{CardId: "question-" + it.Question, Card: &chat.GoogleAppsCardV1Card{Sections: []*chat.GoogleAppsCardV1Section{{
		Widgets: []*chat.GoogleAppsCardV1Widget{{TextParagraph: &chat.GoogleAppsCardV1TextParagraph{
			Text: fmt.Sprintf("<b>%s</b> answered: %s", escape(who), escape(it.Label)),
		}}},
	}}}}
}

// escape keeps a card's text from being read as its HTML.
func escape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(s)
}

// MarkAnswered is the inbox's Answered: it takes the buttons off the question's card and says
// who answered. A failure is logged, never raised: the answer is in the inbox already.
func MarkAnswered(g *Google, logger *slog.Logger) func(context.Context, Item) {
	return func(ctx context.Context, it Item) {
		if it.Message == "" {
			return
		}
		err := g.Edit(ctx, it.Message, &chat.Message{CardsV2: []*chat.CardWithId{answeredCard(it)}}, "cardsV2")
		if err != nil && logger != nil {
			logger.Warn("googlechat-mcp: mark a question answered", "err", err)
		}
	}
}
