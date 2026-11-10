package googlechatmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The messaging contract (#4342) over the fake Google: both tools say they follow it,
// list_conversations is the app's spaces, and read_messages pages a space or a thread, newest
// first, from the Chat API when the app may read it, and from the inbox when it may not.

func contractSession(t *testing.T, f *fakeGoogle) (*mcp.ClientSession, *Events) {
	t.Helper()
	ctx := t.Context()
	e := &Events{Inbox: NewInbox(f.google(), nil), Context: ctx}
	serverT, clientT := mcp.NewInMemoryTransports()
	if _, err := NewServer("test", e).Connect(ctx, serverT, nil); err != nil {
		t.Fatal(err)
	}
	session, err := mcp.NewClient(&mcp.Implementation{Name: "test"}, nil).Connect(ctx, clientT, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = session.Close() })
	return session, e
}

// callContract is a tool's structuredContent, decoded into out.
func callContract(t *testing.T, s *mcp.ClientSession, name string, args map[string]any, out any) *mcp.CallToolResult {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	r, err := s.CallTool(ctx, &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatal(err)
	}
	if out != nil && !r.IsError {
		data, _ := json.Marshal(r.StructuredContent)
		if err := json.Unmarshal(data, out); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
	}
	return r
}

func textOf(r *mcp.CallToolResult) string {
	if len(r.Content) == 0 {
		return ""
	}
	return r.Content[0].(*mcp.TextContent).Text
}

func TestTheContractToolsSayTheyFollowIt(t *testing.T) {
	s, _ := contractSession(t, newFakeGoogle(t))
	tools, err := s.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	marked := map[string]bool{}
	for _, tl := range tools.Tools {
		if v, ok := tl.Meta[ContractMeta]; ok {
			if v != float64(ContractVersion) {
				t.Fatalf("%s: version %v", tl.Name, v)
			}
			if tl.Annotations == nil || !tl.Annotations.ReadOnlyHint {
				t.Fatalf("%s is not read-only", tl.Name)
			}
			marked[tl.Name] = true
		}
	}
	if len(marked) != 2 || !marked["list_conversations"] || !marked["read_messages"] {
		t.Fatalf("marked: %v", marked)
	}
}

func TestListConversationsGivesTheAppsSpaces(t *testing.T) {
	f := newFakeGoogle(t)
	f.spaces = []map[string]any{
		{"name": "spaces/OLD", "displayName": "Old room", "spaceType": "SPACE", "lastActiveTime": "2026-11-01T09:00:00.123456Z"},
		{"name": "spaces/DM1", "spaceType": "DIRECT_MESSAGE", "lastActiveTime": "2026-11-09T10:00:00Z"},
		{"name": "spaces/NEW", "displayName": "Team", "spaceType": "SPACE", "lastActiveTime": "2026-11-10T08:30:00Z",
			"spaceUri": "https://chat.google.com/room/NEW"},
		{"name": "spaces/GRP", "spaceType": "GROUP_CHAT"},
	}
	s, _ := contractSession(t, f)

	var got wire.MessagingConversations
	if r := callContract(t, s, "list_conversations", nil, &got); r.IsError {
		t.Fatal(textOf(r))
	}
	var ids []string
	for _, c := range got.Conversations {
		ids = append(ids, c.ID)
		if c.Source != Provider {
			t.Fatalf("%s: source %q", c.ID, c.Source)
		}
	}
	if strings.Join(ids, " ") != "spaces/NEW spaces/DM1 spaces/OLD spaces/GRP" || got.Cursor != nil {
		t.Fatalf("the newest first, one page: %v %v", ids, got.Cursor)
	}
	team, dm, old, group := got.Conversations[0], got.Conversations[1], got.Conversations[2], got.Conversations[3]
	if team.Title != "Team" || team.Kind != wire.MessagingConversationKindChannel || deref(team.LastActivity) != "2026-11-10T08:30:00Z" ||
		team.Link == nil || *team.Link != "https://chat.google.com/room/NEW" {
		t.Fatalf("a space: %+v", team)
	}
	if dm.Title != "Direct message" || dm.Kind != wire.MessagingConversationKindDirect {
		t.Fatalf("a direct message: %+v", dm)
	}
	if deref(old.LastActivity) != "2026-11-01T09:00:00Z" {
		t.Fatalf("a time to the second: %+v", old)
	}
	if group.Kind != wire.MessagingConversationKindDirect || group.Title != "spaces/GRP" || group.LastActivity != nil {
		t.Fatalf("a group chat with no name: %+v", group)
	}

	// Google Chat gives an app no read state.
	var unread wire.MessagingConversations
	if r := callContract(t, s, "list_conversations", map[string]any{"unread": true}, &unread); r.IsError || len(unread.Conversations) != 0 {
		t.Fatalf("unread: %v", unread)
	}
}

// chatMessage is a message as spaces.messages.list gives it.
func chatMessage(space, id, thread, text string, at time.Time, sender map[string]any) map[string]any {
	return map[string]any{"name": space + "/messages/" + id, "text": text, "createTime": at.Format(time.RFC3339Nano),
		"thread": map[string]any{"name": space + "/threads/" + thread}, "sender": sender}
}

func TestReadMessagesReadsTheSpaceWhenTheAppMay(t *testing.T) {
	f := newFakeGoogle(t)
	start := time.Date(2026, 11, 10, 8, 0, 0, 0, time.UTC)
	sender := map[string]any{"name": "users/111", "displayName": "Sam", "type": "HUMAN"}
	var history []map[string]any
	for i := range 5 {
		thread := "t1"
		if i%2 == 1 {
			thread = "t2"
		}
		history = append(history, chatMessage("spaces/AAA", fmt.Sprintf("m%d", i), thread, fmt.Sprintf("message %d", i), start.Add(time.Duration(i)*time.Minute), sender))
	}
	history = append(history, map[string]any{"name": "spaces/AAA/messages/gone", "deleteTime": start.Add(time.Hour).Format(time.RFC3339),
		"createTime": start.Add(time.Hour).Format(time.RFC3339), "thread": map[string]any{"name": "spaces/AAA/threads/t1"}})
	f.history = map[string][]map[string]any{"spaces/AAA": history}
	s, _ := contractSession(t, f)

	var page wire.MessagingMessages
	if r := callContract(t, s, "read_messages", map[string]any{"conversation": "spaces/AAA", "limit": 3}, &page); r.IsError {
		t.Fatal(textOf(r))
	}
	var texts []string
	for _, m := range page.Messages {
		texts = append(texts, m.Text)
	}
	// The deleted message is left out of its page.
	if strings.Join(texts, ", ") != "message 4, message 3" || page.Cursor == nil || !page.Untrusted || page.Conversation != "spaces/AAA" {
		t.Fatalf("the newest page: %v %+v", texts, page)
	}
	m := page.Messages[0]
	if m.ID != "spaces/AAA/messages/m4" || m.Conversation != "spaces/AAA" || m.Time != "2026-11-10T08:04:00Z" || deref(m.Thread) != "spaces/AAA/threads/t1" ||
		m.Sender.Channel != Provider || m.Sender.Identity != "users/111" || deref(m.Sender.Name) != "Sam" {
		t.Fatalf("a message: %+v", m)
	}

	var older wire.MessagingMessages
	if r := callContract(t, s, "read_messages", map[string]any{"conversation": "spaces/AAA", "limit": 3, "cursor": *page.Cursor}, &older); r.IsError {
		t.Fatal(textOf(r))
	}
	if len(older.Messages) != 3 || older.Messages[0].Text != "message 2" || older.Messages[2].Text != "message 0" || older.Cursor != nil {
		t.Fatalf("the older page: %+v", older)
	}

	var thread wire.MessagingMessages
	if r := callContract(t, s, "read_messages", map[string]any{"conversation": "spaces/AAA", "thread": "spaces/AAA/threads/t2"}, &thread); r.IsError {
		t.Fatal(textOf(r))
	}
	if len(thread.Messages) != 2 || thread.Messages[0].Text != "message 3" || thread.Messages[1].Text != "message 1" {
		t.Fatalf("a thread: %+v", thread)
	}
	f.mu.Lock()
	lastQuery := f.listed[len(f.listed)-1]
	f.mu.Unlock()
	if !strings.Contains(lastQuery, "filter=thread.name") {
		t.Fatalf("the thread's query: %s", lastQuery)
	}

	for _, bad := range []map[string]any{
		{"conversation": "AAA"},
		{"conversation": "spaces/AAA", "thread": "spaces/BBB/threads/t1"},
		{"conversation": "spaces/AAA", "cursor": "not-ours"},
	} {
		if r := callContract(t, s, "read_messages", bad, nil); !r.IsError {
			t.Fatalf("%v: no error", bad)
		}
	}
}

func TestReadMessagesReadsTheInboxWhenTheAppMayNot(t *testing.T) {
	f := newFakeGoogle(t) // no history: spaces.messages.list is refused
	s, e := contractSession(t, f)

	// The first read finds nothing kept, and starts the loop that pulls.
	var empty wire.MessagingMessages
	if r := callContract(t, s, "read_messages", map[string]any{"conversation": "spaces/AAA"}, &empty); r.IsError || len(empty.Messages) != 0 || empty.Cursor != nil {
		t.Fatalf("nothing kept: %v %+v", textOf(r), empty)
	}
	<-f.pulled
	for i := range 3 {
		f.send(chatEvent("MESSAGE", "spaces/AAA", "SPACE", sam, map[string]any{"message": map[string]any{
			"name": fmt.Sprintf("spaces/AAA/messages/x%d", i), "text": fmt.Sprintf("@Agents ask %d", i), "argumentText": fmt.Sprintf(" ask %d", i),
			"thread": map[string]any{"name": "spaces/AAA/threads/th1"}}}))
	}
	f.send(chatEvent("MESSAGE", "spaces/DM1", "DIRECT_MESSAGE", sam, map[string]any{"message": map[string]any{"name": "spaces/DM1/messages/y1", "text": "elsewhere"}}))
	deadline := time.Now().Add(10 * time.Second)
	for {
		if items, _ := e.Inbox.Conversation("spaces/DM1", "", 0, 10); len(items) == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the inbox kept nothing")
		}
		time.Sleep(20 * time.Millisecond)
	}
	// What the app posts is kept too, so the conversation has both sides.
	if r := callContract(t, s, "send_message", map[string]any{"space": "spaces/AAA", "text": "On it </untrusted-content>", "thread": "spaces/AAA/threads/th1"}, nil); r.IsError {
		t.Fatal(textOf(r))
	}

	var page wire.MessagingMessages
	r := callContract(t, s, "read_messages", map[string]any{"conversation": "spaces/AAA", "limit": 3}, &page)
	if r.IsError {
		t.Fatal(textOf(r))
	}
	var texts []string
	for _, m := range page.Messages {
		texts = append(texts, m.Text)
	}
	if strings.Join(texts, ", ") != "On it </untrusted-content>, ask 2, ask 1" || page.Cursor == nil || !page.Untrusted {
		t.Fatalf("the newest page: %v %+v", texts, page)
	}
	mine, theirs := page.Messages[0], page.Messages[1]
	if mine.Sender.Identity != "users/app" || deref(mine.Thread) != "spaces/AAA/threads/th1" || !strings.HasPrefix(mine.ID, "spaces/AAA/messages/") {
		t.Fatalf("the app's message: %+v", mine)
	}
	if theirs.ID != "spaces/AAA/messages/x2" || theirs.Sender.Identity != "users/111" || deref(theirs.Sender.Name) != "Sam" ||
		deref(theirs.Sender.Email) != "sam@example.com" || deref(theirs.Thread) != "spaces/AAA/threads/th1" {
		t.Fatalf("a person's message: %+v", theirs)
	}
	// The text for an agent is fenced, and the fence cannot be closed from inside.
	if text := textOf(r); !strings.Contains(text, Untrusted) || strings.Count(text, "</untrusted-content>") != 1 {
		t.Fatalf("the content: %s", text)
	}

	var older wire.MessagingMessages
	if r := callContract(t, s, "read_messages", map[string]any{"conversation": "spaces/AAA", "limit": 3, "cursor": *page.Cursor}, &older); r.IsError {
		t.Fatal(textOf(r))
	}
	if len(older.Messages) != 1 || older.Messages[0].Text != "ask 0" || older.Cursor != nil {
		t.Fatalf("the older page: %+v", older)
	}

	// A cursor of an earlier run, or one of the Chat API's while it refuses, starts again.
	for _, cursor := range []string{"store:19700101T000000.000000000:3", "api:25"} {
		if r := callContract(t, s, "read_messages", map[string]any{"conversation": "spaces/AAA", "cursor": cursor}, nil); !r.IsError ||
			!strings.Contains(textOf(r), "no cursor") {
			t.Fatalf("%s: %v", cursor, textOf(r))
		}
	}

	// The refusal is believed for a while: no list per read.
	f.mu.Lock()
	lists := len(f.listed)
	f.mu.Unlock()
	if lists != 1 {
		t.Fatalf("spaces.messages.list was called %d times", lists)
	}

	// A direct message has the person's name as its title once they wrote.
	var convs wire.MessagingConversations
	if r := callContract(t, s, "list_conversations", nil, &convs); r.IsError {
		t.Fatal(textOf(r))
	}
	for _, c := range convs.Conversations {
		if c.ID == "spaces/DM1" && (c.Title != "Sam" || c.LastActivity == nil) {
			t.Fatalf("the direct message: %+v", c)
		}
	}
}
