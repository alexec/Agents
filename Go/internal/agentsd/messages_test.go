package agentsd

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// fakeMessagingMCP is a server that follows the messaging contract (#4338) over streamable
// HTTP: list_conversations pages its conversations (newest first) by an offset cursor, and
// read_messages gives two messages of any conversation. A slack one also has reply (#4345),
// which gives back what it sent; the email one, as the real one, cannot send.
func fakeMessagingMCP(t *testing.T, source string, conversations []wire.MessagingConversation) *httptest.Server {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete {
			return
		}
		var m struct {
			ID     *int   `json:"id"`
			Method string `json:"method"`
			Params struct {
				Name      string `json:"name"`
				Arguments struct {
					Cursor       string `json:"cursor"`
					Limit        int    `json:"limit"`
					Conversation string `json:"conversation"`
					Thread       string `json:"thread"`
					Text         string `json:"text"`
				} `json:"arguments"`
			} `json:"params"`
		}
		json.NewDecoder(r.Body).Decode(&m)
		if m.ID == nil {
			w.WriteHeader(http.StatusAccepted)
			return
		}
		var result any = map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{"tools": map[string]any{}}}
		meta := map[string]any{"agents/messaging": 1}
		switch m.Method {
		case "tools/list":
			tools := []any{
				map[string]any{"name": "list_conversations", "inputSchema": map[string]any{"type": "object"}, "_meta": meta},
				map[string]any{"name": "read_messages", "inputSchema": map[string]any{"type": "object", "required": []string{"conversation"}}, "_meta": meta},
			}
			if source == "slack" {
				tools = append(tools, map[string]any{"name": "reply", "inputSchema": map[string]any{"type": "object"}, "_meta": meta})
			}
			result = map[string]any{"tools": tools}
		case "tools/call":
			a := m.Params.Arguments
			switch m.Params.Name {
			case "list_conversations":
				from, _ := strconv.Atoi(a.Cursor)
				to := min(len(conversations), from+a.Limit)
				page := wire.MessagingConversations{Conversations: conversations[from:to]}
				if source == "slack" {
					as := "the Slack bot @agents"
					page.ReplyAs = &as
				}
				if to < len(conversations) {
					next := strconv.Itoa(to)
					page.Cursor = &next
				}
				result = map[string]any{"content": []any{}, "structuredContent": page}
			case "read_messages":
				sender := wire.ChannelSender{Channel: source, Identity: "U1"}
				older := "older"
				result = map[string]any{"content": []any{}, "structuredContent": wire.MessagingMessages{Conversation: a.Conversation, Untrusted: true, Cursor: &older,
					Messages: []wire.MessagingMessage{
						{ID: "m2", Conversation: a.Conversation, Sender: sender, Time: "2026-11-09T10:01:00Z", Text: "second"},
						{ID: "m1", Conversation: a.Conversation, Sender: sender, Time: "2026-11-09T10:00:00Z", Text: "first"},
					}}}
			case "reply":
				sent := wire.MessagingMessage{ID: "m3", Conversation: a.Conversation, Sender: wire.ChannelSender{Channel: source, Identity: "UBOT"},
					Time: "2026-11-09T10:02:00Z", Text: a.Text}
				if a.Thread != "" {
					sent.Thread = &a.Thread
				}
				result = map[string]any{"content": []any{}, "structuredContent": sent}
			}
		}
		b, _ := json.Marshal(result)
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"jsonrpc":"2.0","id":%d,"result":%s}`, *m.ID, b)
	}))
	t.Cleanup(s.Close)
	return s
}

func conversationAt(source, id, at string) wire.MessagingConversation {
	return wire.MessagingConversation{Source: source, ID: id, Title: id, Kind: wire.MessagingConversationKindChannel, LastActivity: &at}
}

// messages/conversations (#4343) merges the conversations of every Messaging connector that
// follows the contract by lastActivity, newest first, a page at a time, with no conversation
// given twice or left out across pages; a connector that does not follow the contract is left
// out with no error, and one that cannot be reached is left out with its error.
// messages/read reads one conversation from its connector, as outside content.
func TestMessagesMergeEveryContractConnector(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	folder := gitFolder(t, "")
	c.call(t, 1, "folders/add", map[string]any{"folder": "file://" + folder})

	slack := fakeMessagingMCP(t, "slack", []wire.MessagingConversation{
		conversationAt("slack", "C5", "2026-11-09T10:05:00Z"),
		conversationAt("slack", "C3", "2026-11-09T10:03:00Z"),
		conversationAt("slack", "C2", "2026-11-09T10:02:00-00:00"),
	})
	email := fakeMessagingMCP(t, "email", []wire.MessagingConversation{
		conversationAt("email", "T6", "2026-11-09T11:06:00+01:00"), // 10:06Z
		conversationAt("email", "T4", "2026-11-09T10:04:00Z"),
		conversationAt("email", "T1", "2026-11-09T10:01:00Z"),
	})
	var calls atomic.Int32
	discord := fakeSlackMCP(t, &calls)
	os.MkdirAll(filepath.Join(home, ".agents"), 0o755)
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), []byte(`{"mcpServers": {
		"slack": {"type": "http", "url": "`+slack.URL+`"},
		"email": {"type": "http", "url": "`+email.URL+`"},
		"discord": {"type": "http", "url": "`+discord.URL+`"},
		"gmail": {"type": "http", "url": "http://127.0.0.1:1/mcp"},
		"kb": {"type": "http", "url": "https://kb.example.com/mcp"}}}`), 0o644)

	var ids []string
	var cursor *string
	for id := 2; ; id++ {
		params := map[string]any{"limit": 2}
		if cursor != nil {
			params["cursor"] = *cursor
		}
		var page wire.MessagesConversations
		if err := json.Unmarshal(c.call(t, id, "messages/conversations", params), &page); err != nil {
			t.Fatal(err)
		}
		if len(page.Errors) != 1 || page.Errors[0].Server != "gmail" || page.Errors[0].Folder != folder || page.Errors[0].Message == "" {
			t.Fatalf("page %d's errors: %+v", id, page.Errors)
		}
		for _, m := range page.Conversations {
			if m.Folder != folder || m.Server != m.Conversation.Source {
				t.Fatalf("conversation: %+v", m)
			}
			// Only the connector with a reply tool says who a reply goes as (#4345).
			if (m.Server == "slack") != (m.ReplyAs != nil) || m.ReplyAs != nil && *m.ReplyAs != "the Slack bot @agents" {
				t.Fatalf("replyAs: %+v", m)
			}
			ids = append(ids, m.Conversation.ID)
		}
		if cursor = page.Cursor; cursor == nil || id > 10 {
			break
		}
	}
	if fmt.Sprint(ids) != "[T6 C5 T4 C3 C2 T1]" {
		t.Fatalf("merged: %v", ids)
	}
	if calls.Load() != 0 {
		t.Fatalf("a connector that is not the contract's was called: %d", calls.Load())
	}

	var read wire.MessagesRead
	json.Unmarshal(c.call(t, 20, "messages/read", map[string]any{"server": "slack", "folder": folder, "conversation": "C5"}), &read)
	if read.Server != "slack" || read.Conversation != "C5" || !read.Untrusted || len(read.Messages) != 2 ||
		read.Messages[0].Text != "second" || read.Cursor == nil || *read.Cursor != "older" {
		t.Fatalf("read: %+v", read)
	}
	if e := c.callError(t, 21, "messages/read", map[string]any{"server": "kb", "folder": folder, "conversation": "C5"}); e == nil || e.Code != CodeInvalidParams {
		t.Fatalf("not a messaging connector: %+v", e)
	}
	if e := c.callError(t, 22, "messages/read", map[string]any{"server": "discord", "folder": folder, "conversation": "C5"}); e == nil || e.Code != CodeServer {
		t.Fatalf("not the contract's: %+v", e)
	}
	if e := c.callError(t, 23, "messages/conversations", map[string]any{"cursor": "nope!"}); e == nil || e.Code != CodeInvalidParams {
		t.Fatalf("a bad cursor: %+v", e)
	}

	// messages/reply (#4345) sends by the connector's reply tool, and gives what it sent; a
	// connector with no reply tool, a reply with no text and a connector that is not one say so.
	var replied wire.MessagesReplied
	json.Unmarshal(c.call(t, 30, "messages/reply", map[string]any{"server": "slack", "folder": folder, "conversation": "C5",
		"thread": "1.2", "text": "On it."}), &replied)
	if replied.Server != "slack" || replied.Folder != folder || replied.Conversation != "C5" || replied.Message.ID != "m3" ||
		replied.Message.Text != "On it." || replied.Message.Thread == nil || *replied.Message.Thread != "1.2" {
		t.Fatalf("reply: %+v", replied)
	}
	if e := c.callError(t, 31, "messages/reply", map[string]any{"server": "email", "folder": folder, "conversation": "T4", "text": "hi"}); e == nil ||
		e.Code != CodeServer || e.Message != "email: It can't send a reply." {
		t.Fatalf("no reply tool: %+v", e)
	}
	if e := c.callError(t, 32, "messages/reply", map[string]any{"server": "slack", "folder": folder, "conversation": "C5", "text": "  "}); e == nil || e.Code != CodeInvalidParams {
		t.Fatalf("no text: %+v", e)
	}
	if e := c.callError(t, 33, "messages/reply", map[string]any{"server": "kb", "folder": folder, "conversation": "C5", "text": "hi"}); e == nil || e.Code != CodeInvalidParams {
		t.Fatalf("not a messaging connector: %+v", e)
	}
}

// A connector whose page is kept only in part is asked for the same page again, and what was
// kept is skipped; one that failed is asked again from where it was.
func TestMergeMessagesPages(t *testing.T) {
	a := messagesConnector{name: "slack", folder: "/f", scope: "~"}
	b := messagesConnector{name: "email", folder: "/f", scope: "/f"}
	bad := messagesConnector{name: "gmail", folder: "/f", scope: "~"}
	from := messagesCursor{a.key(): {Cursor: "p1", Skip: 1}, bad.key(): {Cursor: "g"}}
	pages := []messagesPage{
		{connector: a, from: from[a.key()], conversations: []wire.MessagingConversation{
			conversationAt("slack", "C3", "2026-11-09T10:03:00Z"), conversationAt("slack", "C1", "2026-11-09T10:01:00Z")}, next: "p2"},
		{connector: b, conversations: []wire.MessagingConversation{conversationAt("email", "T2", "2026-11-09T10:02:00Z")}},
		{connector: bad, from: from[bad.key()], err: docsSearchError("down")},
	}
	out, next, more := mergeMessagesPages(pages, from, 2)
	if len(out.Conversations) != 2 || out.Conversations[0].Conversation.ID != "C3" || out.Conversations[1].Conversation.ID != "T2" || !more {
		t.Fatalf("merged: %+v, more %v", out, more)
	}
	if next[a.key()] != (messagesConnectorCursor{Cursor: "p1", Skip: 2}) || !next[b.key()].Done || next[bad.key()] != (messagesConnectorCursor{Cursor: "g"}) {
		t.Fatalf("next: %+v", next)
	}
	if len(out.Errors) != 1 || out.Errors[0].Server != "gmail" {
		t.Fatalf("errors: %+v", out.Errors)
	}
}
