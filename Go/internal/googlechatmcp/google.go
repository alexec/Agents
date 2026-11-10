package googlechatmcp

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"time"

	chat "google.golang.org/api/chat/v1"
	"google.golang.org/api/googleapi"
	"google.golang.org/api/option"
	pubsub "google.golang.org/api/pubsub/v1"
)

// Google is the two APIs, with Google's own clients (google.golang.org/api, which the module
// already carries): Pub/Sub, to pull the app's events and acknowledge them, and the Chat API,
// to list the app's spaces, post and edit its messages, and read a space's messages. All sign
// in as the app's service account. The account is read at each call, so a key saved after the
// server started is used.
type Google struct {
	Account func() (Account, error)

	mu      sync.Mutex
	key     string
	chat    *chat.Service
	reader  *chat.Service
	pubsub  *pubsub.Service
	account Account
	// refusedHistory is when the Chat API last refused to read messages: the app has no
	// chat.app.messages.readonly, which a Workspace admin approves (#4342).
	refusedHistory time.Time
}

// historyRetry is how long a refusal to read messages is believed, before the server asks again.
const historyRetry = 10 * time.Minute

// services are the clients for the account as it is now, made again when it changed.
func (g *Google) services(ctx context.Context) (*chat.Service, *pubsub.Service, Account, error) {
	c, _, p, a, err := g.clients(ctx)
	return c, p, a, err
}

// clients are services, with the Chat API client that reads messages as the app
// (chat.app.messages.readonly) in the middle.
func (g *Google) clients(ctx context.Context) (*chat.Service, *chat.Service, *pubsub.Service, Account, error) {
	a, err := g.Account()
	if err != nil {
		return nil, nil, nil, Account{}, err
	}
	key := string(a.Credentials) + "\x00" + a.Subscription + "\x00" + a.ChatURL + "\x00" + a.PubSubURL
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.chat != nil && g.key == key {
		return g.chat, g.reader, g.pubsub, g.account, nil
	}
	// The services keep the context only to sign in; a call's own context ends the call.
	background := context.WithoutCancel(ctx)
	chatOptions := []option.ClientOption{option.WithScopes(chat.ChatBotScope)}
	readerOptions := []option.ClientOption{option.WithScopes(chat.ChatAppMessagesReadonlyScope)}
	pubsubOptions := []option.ClientOption{option.WithScopes(pubsub.PubsubScope)}
	if a.ChatURL != "" || a.PubSubURL != "" {
		plain := option.WithHTTPClient(&http.Client{Timeout: 2 * time.Minute})
		chatOptions = []option.ClientOption{plain, option.WithEndpoint(a.ChatURL)}
		readerOptions = chatOptions
		pubsubOptions = []option.ClientOption{plain, option.WithEndpoint(a.PubSubURL)}
	} else {
		creds := option.WithAuthCredentialsJSON(option.ServiceAccount, a.Credentials)
		chatOptions = append(chatOptions, creds)
		readerOptions = append(readerOptions, creds)
		pubsubOptions = append(pubsubOptions, creds)
	}
	c, err := chat.NewService(background, chatOptions...)
	if err != nil {
		return nil, nil, nil, Account{}, fmt.Errorf("the Chat API client: %w", err)
	}
	r, err := chat.NewService(background, readerOptions...)
	if err != nil {
		return nil, nil, nil, Account{}, fmt.Errorf("the Chat API client: %w", err)
	}
	p, err := pubsub.NewService(background, pubsubOptions...)
	if err != nil {
		return nil, nil, nil, Account{}, fmt.Errorf("the Pub/Sub client: %w", err)
	}
	g.key, g.chat, g.reader, g.pubsub, g.account, g.refusedHistory = key, c, r, p, a, time.Time{}
	return c, r, p, a, nil
}

// Received is one Pub/Sub message: its id, when it was published, its data, and the id to
// acknowledge it by.
type Received struct {
	ID, AckID string
	Published time.Time
	Data      []byte
}

// Pull waits for up to max messages on the subscription. Pub/Sub answers when it has some, or
// after a while with none.
func (g *Google) Pull(ctx context.Context, max int) ([]Received, error) {
	_, p, a, err := g.services(ctx)
	if err != nil {
		return nil, err
	}
	answer, err := p.Projects.Subscriptions.Pull(a.Subscription, &pubsub.PullRequest{MaxMessages: int64(max)}).Context(ctx).Do()
	if err != nil {
		return nil, apiError("Pub/Sub", err)
	}
	out := make([]Received, 0, len(answer.ReceivedMessages))
	for _, m := range answer.ReceivedMessages {
		if m.Message == nil {
			continue
		}
		r := Received{ID: m.Message.MessageId, AckID: m.AckId}
		r.Published, _ = time.Parse(time.RFC3339Nano, m.Message.PublishTime)
		r.Data, err = decodeBase64(m.Message.Data)
		if err != nil {
			r.Data = nil
		}
		out = append(out, r)
	}
	return out, nil
}

// Ack acknowledges messages, so Pub/Sub does not send them again.
func (g *Google) Ack(ctx context.Context, ackIDs []string) error {
	if len(ackIDs) == 0 {
		return nil
	}
	_, p, a, err := g.services(ctx)
	if err != nil {
		return err
	}
	_, err = p.Projects.Subscriptions.Acknowledge(a.Subscription, &pubsub.AcknowledgeRequest{AckIds: ackIDs}).Context(ctx).Do()
	return apiError("Pub/Sub", err)
}

// Space is a space the app is in: LastActive is its newest message's time (RFC 3339) and URI
// the space in Google Chat, when the Chat API gives them.
type Space struct {
	Name, DisplayName, Type string
	LastActive, URI         string
}

// Spaces lists the spaces the app is in, at most limit.
func (g *Google) Spaces(ctx context.Context, limit int) ([]Space, error) {
	out := []Space{}
	token := ""
	for len(out) < limit {
		page, next, err := g.SpacesPage(ctx, min(100, limit-len(out)), token)
		if err != nil {
			return nil, err
		}
		out = append(out, page...)
		if token = next; token == "" {
			break
		}
	}
	return out, nil
}

// SpacesPage is one page of the spaces the app is in, at most size, after token, and the
// next page's token ("" on the last).
func (g *Google) SpacesPage(ctx context.Context, size int, token string) ([]Space, string, error) {
	c, _, _, err := g.services(ctx)
	if err != nil {
		return nil, "", err
	}
	call := c.Spaces.List().PageSize(int64(size)).Context(ctx)
	if token != "" {
		call = call.PageToken(token)
	}
	page, err := call.Do()
	if err != nil {
		return nil, "", apiError("the Chat API", err)
	}
	out := make([]Space, 0, len(page.Spaces))
	for _, s := range page.Spaces {
		out = append(out, Space{Name: s.Name, DisplayName: s.DisplayName, Type: s.SpaceType, LastActive: s.LastActiveTime, URI: s.SpaceUri})
	}
	return out, page.NextPageToken, nil
}

// ErrNoHistory is the Chat API's refusal to read a space's messages as the app: it has no
// chat.app.messages.readonly, which a Workspace admin approves once.
var ErrNoHistory = errors.New("the Chat app cannot read a space's messages: a Workspace admin has not approved chat.app.messages.readonly")

// Messages is one page of a space's messages as the app, the newest first: at most size, in
// thread only when it is a thread's name, after token; and the next page's token. It is
// ErrNoHistory when the app may not read them, and stays so for historyRetry without asking.
func (g *Google) Messages(ctx context.Context, space, thread string, size int, token string) ([]*chat.Message, string, error) {
	_, r, _, _, err := g.clients(ctx)
	if err != nil {
		return nil, "", err
	}
	g.mu.Lock()
	refused := !g.refusedHistory.IsZero() && time.Since(g.refusedHistory) < historyRetry
	g.mu.Unlock()
	if refused {
		return nil, "", ErrNoHistory
	}
	call := r.Spaces.Messages.List(space).OrderBy("createTime DESC").PageSize(int64(size)).Context(ctx)
	if thread != "" {
		call = call.Filter("thread.name = " + thread)
	}
	if token != "" {
		call = call.PageToken(token)
	}
	page, err := call.Do()
	var refusal *googleapi.Error
	if errors.As(err, &refusal) && (refusal.Code == http.StatusForbidden || refusal.Code == http.StatusUnauthorized) {
		g.mu.Lock()
		g.refusedHistory = time.Now()
		g.mu.Unlock()
		return nil, "", ErrNoHistory
	}
	if err != nil {
		return nil, "", apiError("the Chat API", err)
	}
	return page.Messages, page.NextPageToken, nil
}

// Post posts a message as the app in space, in thread when it is a thread's name.
func (g *Google) Post(ctx context.Context, space, thread string, m *chat.Message) (*chat.Message, error) {
	c, _, _, err := g.services(ctx)
	if err != nil {
		return nil, err
	}
	call := c.Spaces.Messages.Create(space, m).Context(ctx)
	if thread != "" {
		m.Thread = &chat.Thread{Name: thread}
		call = call.MessageReplyOption("REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD")
	}
	posted, err := call.Do()
	return posted, apiError("the Chat API", err)
}

// Edit changes the given fields of one of the app's messages.
func (g *Google) Edit(ctx context.Context, name string, m *chat.Message, fields string) error {
	c, _, _, err := g.services(ctx)
	if err != nil {
		return err
	}
	_, err = c.Spaces.Messages.Patch(name, m).UpdateMask(fields).Context(ctx).Do()
	return apiError("the Chat API", err)
}

// apiError says which API refused, and what to check for the usual refusals.
func apiError(api string, err error) error {
	if err == nil {
		return nil
	}
	var g *googleapi.Error
	if !errors.As(err, &g) {
		return fmt.Errorf("%s: %w", api, err)
	}
	switch g.Code {
	case http.StatusUnauthorized:
		return &NotSignedInError{fmt.Sprintf("%s refused the key: check GOOGLE_CHAT_CREDENTIALS", api)}
	case http.StatusForbidden:
		return fmt.Errorf("%s refused: the service account needs the Pub/Sub Subscriber role on the subscription, and the Chat app must be in the space (%s)", api, g.Message)
	case http.StatusNotFound:
		return fmt.Errorf("%s found no such thing: check GOOGLE_CHAT_SUBSCRIPTION, or the space or message name (%s)", api, g.Message)
	}
	return fmt.Errorf("%s: %s (%d)", api, g.Message, g.Code)
}

// NotSignedInError is a refused key.
type NotSignedInError struct{ Message string }

func (e *NotSignedInError) Error() string { return e.Message }
