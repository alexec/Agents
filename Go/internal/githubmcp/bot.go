package githubmcp

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/connections"
)

// The person's agents' bot (#3858). When the person made one and installed it on the owner of
// this folder's repository, the official toolsets post as <login>-agents[bot], with an
// installation token that the bot's key on this machine makes. Otherwise, and for the tools
// that need a permission the bot does not have (CI secrets, variables, environments, deploys,
// new repositories, teams: spec 3856 §1), the person's user token, as before.

// Identity is the token the official toolsets send, and the bot when it is the bot's.
type Identity struct {
	user func() string
	repo func(ctx context.Context) (string, error)
	bot  *connections.BotTokens

	mu    sync.Mutex
	owner string
}

// NewIdentity is the bot's token for repo's owner when there is one, else user.
func NewIdentity(user func() string, repo func(ctx context.Context) (string, error)) *Identity {
	return &Identity{user: user, repo: repo, bot: connections.NewBotTokens(connections.FromEnv())}
}

func (i *Identity) account() string {
	i.mu.Lock()
	defer i.mu.Unlock()
	if i.owner == "" && i.repo != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if r, err := i.repo(ctx); err == nil {
			i.owner, _, _ = strings.Cut(r, "/")
		}
	}
	return i.owner
}

// Bot is the bot whose token Token sends; ok is false when it sends the user token.
func (i *Identity) Bot() (connections.Bot, bool) {
	if i.bot == nil {
		return connections.Bot{}, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	t, b := i.bot.For(ctx, i.account())
	return b, t != ""
}

// Token is the bot's installation token, or the user token.
func (i *Identity) Token() string {
	if i.bot != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		if t, _ := i.bot.For(ctx, i.account()); t != "" {
			return t
		}
	}
	return i.user()
}

// The writes whose text names the person: a body that ends in the footer, or a commit message
// that ends in the trailer.
var (
	bodyWrite    = regexp.MustCompile(`^/repos/[^/]+/[^/]+/(issues(/\d+(/comments)?|/comments/\d+)?|pulls(/\d+(/comments|/reviews)?|/comments/\d+(/replies)?|/\d+/comments/\d+/replies)?)$`)
	messageWrite = regexp.MustCompile(`^/repos/[^/]+/[^/]+/(contents/.+|git/commits)$`)
)

// SignTransport adds the bot's footer or trailer to each write the bot makes, so the person it
// acts for is named on GitHub (spec 3856 §3). bot says whether the bot's token is sent.
type SignTransport struct {
	Next http.RoundTripper
	Bot  func() (connections.Bot, bool)
}

func (t *SignTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.Body == nil || (req.Method != http.MethodPost && req.Method != http.MethodPatch && req.Method != http.MethodPut && req.Method != http.MethodDelete) {
		return t.Next.RoundTrip(req)
	}
	path := strings.TrimPrefix(req.URL.Path, "/api/v3")
	field, add := "", ""
	switch {
	case bodyWrite.MatchString(path):
		field = "body"
	case messageWrite.MatchString(path):
		field = "message"
	default:
		return t.Next.RoundTrip(req)
	}
	b, ok := t.Bot()
	if !ok {
		return t.Next.RoundTrip(req)
	}
	if field == "body" {
		add = b.Footer()
	} else {
		add = b.Trailer()
	}
	data, err := io.ReadAll(req.Body)
	_ = req.Body.Close()
	if err != nil {
		return nil, err
	}
	data = Sign(data, field, add)
	out := req.Clone(req.Context())
	out.Body = io.NopCloser(bytes.NewReader(data))
	out.ContentLength = int64(len(data))
	out.Header.Set("Content-Length", strconv.Itoa(len(data)))
	out.GetBody = func() (io.ReadCloser, error) { return io.NopCloser(bytes.NewReader(data)), nil }
	return t.Next.RoundTrip(out)
}

// Sign is a JSON body with add at the end of its string field, after a blank line, once. A body
// that is not a JSON object, or has no such string, is as it was: a label change has no body.
func Sign(data []byte, field, add string) []byte {
	var m map[string]json.RawMessage
	if json.Unmarshal(data, &m) != nil {
		return data
	}
	raw, ok := m[field]
	var text string
	if !ok || json.Unmarshal(raw, &text) != nil || text == "" || strings.Contains(text, add) {
		return data
	}
	sep := "\n\n"
	if field == "message" && trailerLine.MatchString(lastLine(text)) {
		sep = "\n"
	}
	signed, err := json.Marshal(strings.TrimRight(text, "\n") + sep + add)
	if err != nil {
		return data
	}
	m[field] = signed
	out, err := json.Marshal(m)
	if err != nil {
		return data
	}
	return out
}

var trailerLine = regexp.MustCompile(`^[A-Za-z-]+: .+`)

func lastLine(s string) string {
	s = strings.TrimRight(s, "\n")
	if i := strings.LastIndexByte(s, '\n'); i >= 0 {
		return s[i+1:]
	}
	return s
}
