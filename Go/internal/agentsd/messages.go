package agentsd

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/Go/wire"
)

// The messages reads (#4343): messages/conversations lists the conversations of every
// connector in the Messaging slot (#1787) that follows the messaging contract
// (docs/reference/messaging-contract.md), and messages/read reads one conversation, for the
// Messages page (#4337). Here, on the machine, because the connectors' tokens are here; the
// clients merge the machines' answers, one copy per conversation, and the control plane only
// relays them: it never stores message text (docs/explanation/direction.md).
//
// A connector follows the contract when its list_conversations and read_messages tools both
// have "agents/messaging": 1 in their _meta. A list is one page of every such connector,
// merged by lastActivity, as the forge lists merge forges (forge.go): each connector is asked
// for a page, the newest of them all are kept, and each connector's cursor goes on after the
// last of its own kept. A connector's page has one cursor, after its whole page, so a
// connector whose page was kept only in part is asked for the same page again, and the part
// already given is skipped. A connector that fails or does not answer in time is left out,
// with its error; the others still come.
const (
	// messagesMost bounds a page; messagesDefault is a page when not said (the contract's).
	messagesMost    = 100
	messagesDefault = 20
	// messagesTimeout is the most one connector's call takes.
	messagesTimeout = 15 * time.Second
	// messagesAtOnce is the most connectors one list reads at the same time.
	messagesAtOnce = 6
	// messagingContractVersion is the contract's version that the daemon reads.
	messagingContractVersion = 1
)

// errNotContract is a connector whose tools do not follow the messaging contract.
var errNotContract = docsSearchError("It doesn't follow the messaging contract.")

func (d *Daemon) registerMessages() {
	On(d, wire.CallMessagesConversations, func(ctx context.Context, _ *Client, r wire.MessagesConversationsRequest) (wire.MessagesConversations, error) {
		return d.messagesConversations(ctx, r)
	})
	On(d, wire.CallMessagesRead, func(ctx context.Context, _ *Client, r wire.MessagesReadRequest) (wire.MessagesRead, error) {
		return d.messagesRead(ctx, r)
	})
}

// messagesConnector is one connector a list reads: its name in mcp.json and the folder it is
// read from. scope is where its entry is (a folder, or ~ for the person's), so a connector in
// the person's mcp.json is read once however many folders it reaches.
type messagesConnector struct {
	name, folder, scope string
}

func (c messagesConnector) key() string { return c.scope + "\x00" + c.name }

// messagesConnectors are the Messaging slot's connectors of folders, each once.
func (d *Daemon) messagesConnectors(folders []string) []messagesConnector {
	var out []messagesConnector
	seen := map[string]bool{}
	for _, f := range folders {
		own, _ := readMCPFile(filepath.Join(f, ".agents", "mcp.json"))
		for _, e := range d.messagingServers(f) {
			// A folder's own entry comes first, as a session reaches it (eventServerNamed).
			scope := "~"
			if slices.ContainsFunc(own, func(m mcpEntry) bool { return m.name == e.name }) {
				scope = f
			}
			c := messagesConnector{e.name, f, scope}
			if !seen[c.key()] {
				seen[c.key()] = true
				out = append(out, c)
			}
		}
	}
	return out
}

// messagesCursor is a list's cursor, one per connector by its key, so a page goes on where
// each connector stopped.
type messagesCursor map[string]messagesConnectorCursor

// messagesConnectorCursor is where one connector goes on: its own cursor, the part of that
// page already given (skip), or done when its list has ended.
type messagesConnectorCursor struct {
	Cursor string `json:"c,omitempty"`
	Skip   int    `json:"s,omitempty"`
	Done   bool   `json:"d,omitempty"`
}

func (c messagesCursor) text() *string {
	b, _ := json.Marshal(c)
	s := base64.RawURLEncoding.EncodeToString(b)
	return &s
}

func messagesCursorOf(s *string) (messagesCursor, error) {
	c := messagesCursor{}
	if s == nil || *s == "" {
		return c, nil
	}
	b, err := base64.RawURLEncoding.DecodeString(*s)
	if err != nil || json.Unmarshal(b, &c) != nil {
		return messagesCursor{}, errors.New("the cursor is not one a list gave")
	}
	return c, nil
}

// messagesLimit is r's limit, or the default.
func messagesLimit(method string, limit *int64) (int, error) {
	if limit == nil {
		return messagesDefault, nil
	}
	if *limit < 1 || *limit > messagesMost {
		return 0, Invalid("%s: limit is 1 to %d", method, messagesMost)
	}
	return int(*limit), nil
}

// messagesConversations is a page of the conversations of r.folder's connectors, or of every
// folder's.
func (d *Daemon) messagesConversations(ctx context.Context, r wire.MessagesConversationsRequest) (wire.MessagesConversations, error) {
	const method = "messages/conversations"
	limit, err := messagesLimit(method, r.Limit)
	if err != nil {
		return wire.MessagesConversations{}, err
	}
	cursor, err := messagesCursorOf(r.Cursor)
	if err != nil {
		return wire.MessagesConversations{}, Invalid("%s: %v", method, err)
	}
	folders := d.folderPaths()
	if f := deref(r.Folder); f != "" {
		if !slices.Contains(folders, f) {
			return wire.MessagesConversations{}, Invalid("%s: %s is not a folder on this machine", method, f)
		}
		folders = []string{f}
	}
	secrets := d.secrets()
	var connectors []messagesConnector
	for _, c := range d.messagesConnectors(folders) {
		if !cursor[c.key()].Done {
			connectors = append(connectors, c)
		}
	}
	pages := make([]messagesPage, len(connectors))
	var wg sync.WaitGroup
	at := make(chan struct{}, messagesAtOnce)
	for i, c := range connectors {
		wg.Go(func() {
			at <- struct{}{}
			defer func() { <-at }()
			pages[i] = d.messagesPageOf(ctx, c, cursor[c.key()], limit, r.Unread, secrets)
		})
	}
	wg.Wait()
	pages = slices.DeleteFunc(pages, func(p messagesPage) bool { return errors.Is(p.err, errNotContract) })
	out, next, more := mergeMessagesPages(pages, cursor, limit)
	if more {
		out.Cursor = next.text()
	}
	return out, nil
}

// messagesPage is one connector's page of a list, past the part of it already given; next is
// its own cursor after the page ("" at its end); or why the connector could not be read.
type messagesPage struct {
	connector     messagesConnector
	from          messagesConnectorCursor
	conversations []wire.MessagingConversation
	next          string
	err           error
}

// messagesPageOf asks one connector for its page from where its cursor says.
func (d *Daemon) messagesPageOf(ctx context.Context, c messagesConnector, from messagesConnectorCursor, limit int, unread *bool, secrets map[string]string) messagesPage {
	p := messagesPage{connector: c, from: from}
	args := map[string]any{"limit": min(messagesMost, limit+from.Skip)}
	if from.Cursor != "" {
		args["cursor"] = from.Cursor
	}
	if unread != nil && *unread {
		args["unread"] = true
	}
	var page wire.MessagingConversations
	p.err = d.callMessaging(ctx, c, "list_conversations", args, secrets, &page)
	if p.err != nil {
		return p
	}
	got := slices.DeleteFunc(page.Conversations, func(m wire.MessagingConversation) bool { return m.ID == "" })
	p.conversations = got[min(from.Skip, len(got)):]
	p.next = deref(page.Cursor)
	return p
}

// mergeMessagesPages keeps the newest limit conversations of the connectors' pages, each
// connector's in its own order, and the cursor that goes on after them: a connector whose page
// was all kept goes on from its own next cursor (done when it has none), one whose page was
// kept in part asks for that page again and skips what was kept, and one that failed is asked
// again from where it was. more says some connector goes on.
func mergeMessagesPages(pages []messagesPage, from messagesCursor, limit int) (wire.MessagesConversations, messagesCursor, bool) {
	out := wire.MessagesConversations{Conversations: []wire.MessagesConversation{}}
	taken := make([]int, len(pages))
	for len(out.Conversations) < limit {
		best := -1
		for n, p := range pages {
			if taken[n] < len(p.conversations) && (best < 0 ||
				messagesNewer(p.conversations[taken[n]], pages[best].conversations[taken[best]])) {
				best = n
			}
		}
		if best < 0 {
			break
		}
		p := pages[best]
		out.Conversations = append(out.Conversations, wire.MessagesConversation{
			Server: p.connector.name, Folder: p.connector.folder, Conversation: p.conversations[taken[best]]})
		taken[best]++
	}
	next := messagesCursor{}
	for k, v := range from {
		next[k] = v
	}
	more := false
	for n, p := range pages {
		key := p.connector.key()
		switch {
		case p.err != nil:
			out.Errors = append(out.Errors, wire.MessagesError{Server: p.connector.name, Folder: p.connector.folder, Message: p.err.Error()})
		case taken[n] == len(p.conversations) && p.next == "":
			next[key] = messagesConnectorCursor{Done: true}
			continue
		case taken[n] == len(p.conversations):
			next[key] = messagesConnectorCursor{Cursor: p.next}
		default:
			next[key] = messagesConnectorCursor{Cursor: p.from.Cursor, Skip: p.from.Skip + taken[n]}
		}
		more = more || p.err == nil
	}
	return out, next, more
}

// messagesNewer is whether a's lastActivity is after b's; a conversation with none, or one
// that is not a time, is the oldest.
func messagesNewer(a, b wire.MessagingConversation) bool {
	at, aok := messagesTime(a.LastActivity)
	bt, bok := messagesTime(b.LastActivity)
	return aok && (!bok || at.After(bt))
}

func messagesTime(s *string) (time.Time, bool) {
	if s == nil {
		return time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339Nano, *s)
	return t, err == nil
}

// messagesRead is one page of one conversation's messages, from the connector that lists it.
func (d *Daemon) messagesRead(ctx context.Context, r wire.MessagesReadRequest) (wire.MessagesRead, error) {
	const method = "messages/read"
	limit, err := messagesLimit(method, r.Limit)
	if err != nil {
		return wire.MessagesRead{}, err
	}
	if r.Server == "" || r.Conversation == "" {
		return wire.MessagesRead{}, Invalid("%s: server and conversation are needed", method)
	}
	if !slices.Contains(d.folderPaths(), r.Folder) {
		return wire.MessagesRead{}, Invalid("%s: %s is not a folder on this machine", method, r.Folder)
	}
	if !slices.ContainsFunc(d.messagingServers(r.Folder), func(e docsServerEntry) bool { return e.name == r.Server }) {
		return wire.MessagesRead{}, Invalid("%s: %s is not a messaging connector of %s", method, r.Server, r.Folder)
	}
	args := map[string]any{"conversation": r.Conversation, "limit": limit}
	if c := deref(r.Cursor); c != "" {
		args["cursor"] = c
	}
	if t := deref(r.Thread); t != "" {
		args["thread"] = t
	}
	var page wire.MessagingMessages
	c := messagesConnector{name: r.Server, folder: r.Folder}
	if err := d.callMessaging(ctx, c, "read_messages", args, d.secrets(), &page); err != nil {
		return wire.MessagesRead{}, &Error{Code: CodeServer, Message: r.Server + ": " + err.Error()}
	}
	out := wire.MessagesRead{Server: r.Server, Folder: r.Folder, Conversation: r.Conversation,
		Messages: page.Messages, Cursor: page.Cursor, Untrusted: true}
	if out.Messages == nil {
		out.Messages = []wire.MessagingMessage{}
	}
	return out, nil
}

// callMessaging calls one contract tool of the connector, signed in, and reads its
// structuredContent into into: errNotContract when the connector does not follow the
// contract, or why the call failed, in a sentence.
func (d *Daemon) callMessaging(ctx context.Context, c messagesConnector, tool string, args map[string]any, secrets map[string]string, into any) error {
	s, cwd, err := d.docsServerFor(c.name, c.folder, secrets)
	if err != nil {
		return err
	}
	raw, err := callMessagingTool(ctx, s, cwd, tool, args, messagesTimeout)
	if err != nil {
		return err
	}
	return messagingResult(raw, into)
}

// callMessagingTool connects, checks that the server follows the messaging contract, calls
// tool once with args, and ends: what the call answered.
func callMessagingTool(ctx context.Context, s sdk.McpServer, cwd, tool string, args map[string]any, timeout time.Duration) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var c mcpConn
	switch {
	case s.Stdio != nil:
		sc, err := startStdioMCP(s.Stdio, cwd)
		if err != nil {
			return nil, docsSearchError(mcpFailureOf(err).sentence(timeout))
		}
		c = sc
	case s.Http != nil:
		c = &httpMCP{url: s.Http.Url, headers: s.Http.Headers}
	default:
		return nil, docsSearchError("What came back was not MCP.")
	}
	defer c.end()
	failed := func(err error) error {
		if ctx.Err() != nil {
			err = &mcpCheckFailure{kind: "timedOut"}
		}
		return docsSearchError(mcpFailureOf(err).sentence(timeout))
	}
	if _, err := c.call(ctx, 1, "initialize", map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{},
		"clientInfo": map[string]any{"name": "Agents", "version": "1"}}); err != nil {
		return nil, failed(err)
	}
	if err := c.notify(ctx, "notifications/initialized"); err != nil {
		return nil, failed(err)
	}
	contract := map[string]bool{}
	id := 2
	for cursor := ""; ; id++ {
		params := map[string]any{}
		if cursor != "" {
			params["cursor"] = cursor
		}
		raw, err := c.call(ctx, id, "tools/list", params)
		if err != nil {
			return nil, failed(err)
		}
		var page struct {
			Tools []struct {
				Name string `json:"name"`
				Meta struct {
					Messaging int `json:"agents/messaging"`
				} `json:"_meta"`
			} `json:"tools"`
			NextCursor string `json:"nextCursor"`
		}
		if json.Unmarshal(raw, &page) != nil {
			return nil, docsSearchError("What came back was not MCP.")
		}
		for _, t := range page.Tools {
			if t.Meta.Messaging == messagingContractVersion {
				contract[t.Name] = true
			}
		}
		if page.NextCursor == "" || id > 50 {
			break
		}
		cursor = page.NextCursor
	}
	if !contract["list_conversations"] || !contract["read_messages"] || !contract[tool] {
		return nil, errNotContract
	}
	raw, err := c.call(ctx, id+1, "tools/call", map[string]any{"name": tool, "arguments": args})
	if err != nil {
		return nil, failed(err)
	}
	return raw, nil
}

// messagingResult reads a contract tool's structuredContent into into, or says why it could
// not: the tool's error, or an answer that is not the contract's.
func messagingResult(raw json.RawMessage, into any) error {
	var result struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
		Structured json.RawMessage `json:"structuredContent"`
		IsError    bool            `json:"isError"`
	}
	if json.Unmarshal(raw, &result) != nil {
		return docsSearchError("What came back was not MCP.")
	}
	if result.IsError {
		for _, c := range result.Content {
			if c.Type == "text" && strings.TrimSpace(c.Text) != "" {
				return docsSearchError("It said: " + firstLine(c.Text))
			}
		}
		return docsSearchError("Its call failed.")
	}
	if len(result.Structured) == 0 || json.Unmarshal(result.Structured, into) != nil {
		return docsSearchError("Its answer isn't the messaging contract's.")
	}
	return nil
}
