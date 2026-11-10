package whatsappmcp

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestTheStoreKeepsTheNewestWithinItsLimits(t *testing.T) {
	now := time.Now()
	at := func(ago time.Duration) time.Time { return now.Add(-ago) }
	var msgs []Stored
	for i := range maxStored + 10 {
		msgs = append(msgs, Stored{ID: fmt.Sprint(i), At: at(time.Duration(maxStored+10-i) * time.Second), Text: "x"})
	}
	if kept := bound(msgs, now); len(kept) != maxStored || kept[0].ID != "10" {
		t.Fatalf("by count: %d, from %s", len(kept), kept[0].ID)
	}
	old := []Stored{{ID: "old", At: at(storedFor + time.Hour)}, {ID: "new", At: at(time.Hour)}}
	if kept := bound(old, now); len(kept) != 1 || kept[0].ID != "new" {
		t.Fatalf("by age: %v", kept)
	}
	big := strings.Repeat("x", maxStoreBytes/3)
	large := []Stored{{ID: "a", At: at(3 * time.Hour), Text: big}, {ID: "b", At: at(2 * time.Hour), Text: big}, {ID: "c", At: at(time.Hour), Text: big},
		{ID: "d", At: at(0), Text: "y"}}
	if kept := bound(large, now); len(kept) != 3 || kept[0].ID != "b" {
		t.Fatalf("by size: %d, from %s", len(kept), kept[0].ID)
	}
}

// Each copy of the server (one for each session) adds to the same file, and each reads all of
// it; a message added twice is kept once, and a file that cannot be read is kept aside.
func TestEveryCopyOfTheServerSharesTheStore(t *testing.T) {
	dir := t.TempDir()
	one, two := &Store{Dir: dir}, &Store{Dir: dir}
	now := time.Now().Truncate(time.Second)
	if err := one.Add(fakePhoneNumberID, Stored{ID: "wamid.A", Person: "15551234567", At: now.Add(-time.Minute), Text: "hello"}); err != nil {
		t.Fatal(err)
	}
	if err := two.Add(fakePhoneNumberID, Stored{ID: "wamid.B", Person: "15551234567", Out: true, At: now, Text: "hi"},
		Stored{ID: "wamid.A", Person: "15551234567", At: now.Add(-time.Minute), Text: "hello"}); err != nil {
		t.Fatal(err)
	}
	got, err := one.Messages(fakePhoneNumberID)
	if err != nil || len(got) != 2 || got[0].ID != "wamid.A" || got[1].ID != "wamid.B" || !got[1].Out {
		t.Fatalf("read by the other copy: %+v %v", got, err)
	}
	if other, err := one.Messages("999999999"); err != nil || len(other) != 0 {
		t.Fatalf("another number's: %v %v", other, err)
	}
	p := filepath.Join(dir, fakePhoneNumberID+".json")
	if info, err := os.Stat(p); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("the file: %v %v", info, err)
	}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".tmp") {
			t.Fatalf("a temporary file is left: %s", e.Name())
		}
	}

	if err := os.WriteFile(p, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := one.Messages(fakePhoneNumberID); err == nil {
		t.Fatal("an unreadable store was read as empty")
	}
	if err := one.Add(fakePhoneNumberID, Stored{ID: "wamid.C", Person: "15551234567", At: now, Text: "again"}); err != nil {
		t.Fatal(err)
	}
	if got, _ := one.Messages(fakePhoneNumberID); len(got) != 1 || got[0].ID != "wamid.C" {
		t.Fatalf("after the unreadable file: %+v", got)
	}
	if aside, err := os.ReadFile(filepath.Join(dir, fakePhoneNumberID+".unreadable.json")); err != nil || string(aside) != "{not json" {
		t.Fatalf("kept aside: %q %v", aside, err)
	}
}

// list_conversations and read_messages page the store, newest first, by cursor.
func TestTheConversationsArePagedNewestFirst(t *testing.T) {
	f := newFakeMeta(t)
	inbox := NewInbox(f.accountFunc(), nil)
	inbox.Store = &Store{Dir: t.TempDir()}
	start := time.Now().Add(-time.Hour).Unix()
	var people []map[string]any
	var msgs []map[string]any
	for i := range 5 {
		number := "4477009001" + strconv.Itoa(10+i)
		people = append(people, map[string]any{"wa_id": number, "name": "Person " + strconv.Itoa(i)})
		for j := range 5 {
			m := text("wamid.P"+strconv.Itoa(i)+"M"+strconv.Itoa(j), number, fmt.Sprintf("message %d of person %d", j, i))
			m["timestamp"] = strconv.FormatInt(start+int64(10*i+j), 10)
			msgs = append(msgs, m)
		}
	}
	quote := text("wamid.Q", "447700900114", "about that")
	quote["timestamp"], quote["context"] = strconv.FormatInt(start+100, 10), map[string]any{"id": "wamid.P4M1"}
	msgs = append(msgs, quote)
	if code := deliver(inbox, call(fakePhoneNumberID, people, msgs...), fakeSecret); code != 200 {
		t.Fatal(code)
	}

	server := NewServer("test", f.meta(), inbox)
	ct, st := mcp.NewInMemoryTransports()
	if _, err := server.Connect(t.Context(), st, nil); err != nil {
		t.Fatal(err)
	}
	session, err := mcp.NewClient(&mcp.Implementation{Name: "test"}, nil).Connect(t.Context(), ct, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = session.Close() }()
	call := func(name string, args map[string]any) (map[string]any, string) {
		t.Helper()
		r, err := session.CallTool(t.Context(), &mcp.CallToolParams{Name: name, Arguments: args})
		if err != nil {
			t.Fatal(err)
		}
		text := r.Content[0].(*mcp.TextContent).Text
		if r.IsError {
			return nil, text
		}
		data, _ := json.Marshal(r.StructuredContent)
		var out map[string]any
		_ = json.Unmarshal(data, &out)
		return out, text
	}
	ids := func(list any, key string) string {
		var out []string
		for _, it := range list.([]any) {
			out = append(out, it.(map[string]any)[key].(string))
		}
		return strings.Join(out, " ")
	}

	page, _ := call("list_conversations", map[string]any{"limit": 2})
	if got := ids(page["conversations"], "id"); got != "447700900114 447700900113" || page["cursor"] == nil {
		t.Fatalf("the first page: %v", page)
	}
	page, _ = call("list_conversations", map[string]any{"limit": 2, "cursor": page["cursor"]})
	if got := ids(page["conversations"], "id"); got != "447700900112 447700900111" {
		t.Fatalf("the second page: %v", page)
	}
	page, _ = call("list_conversations", map[string]any{"limit": 2, "cursor": page["cursor"]})
	if got := ids(page["conversations"], "id"); got != "447700900110" || page["cursor"] != nil {
		t.Fatalf("the last page: %v", page)
	}
	if _, said := call("list_conversations", map[string]any{"cursor": "nonsense"}); !strings.Contains(said, "no cursor") {
		t.Fatalf("a cursor not given: %q", said)
	}
	if unread, _ := call("list_conversations", map[string]any{"unread": true}); len(unread["conversations"].([]any)) != 0 {
		t.Fatalf("unread: %v", unread)
	}

	read, _ := call("read_messages", map[string]any{"conversation": "+44 7700 900114", "limit": 4})
	if got := ids(read["messages"], "id"); got != "wamid.Q wamid.P4M4 wamid.P4M3 wamid.P4M2" || read["cursor"] != "wamid.P4M2" {
		t.Fatalf("the first page: %v", read)
	}
	read, _ = call("read_messages", map[string]any{"conversation": "447700900114", "limit": 4, "cursor": read["cursor"]})
	if got := ids(read["messages"], "id"); got != "wamid.P4M1 wamid.P4M0" || read["cursor"] != nil {
		t.Fatalf("the last page: %v", read)
	}
	if thread, _ := call("read_messages", map[string]any{"conversation": "447700900114", "thread": "wamid.P4M1"}); ids(thread["messages"], "id") != "wamid.Q wamid.P4M1" {
		t.Fatalf("a quoted message and its quote: %v", thread)
	}
	if every, _ := call("read_messages", map[string]any{"limit": 3}); ids(every["messages"], "id") != "wamid.Q wamid.P4M4 wamid.P4M3" || every["conversation"] != "" {
		t.Fatalf("every person's: %v", every)
	}
	if _, said := call("read_messages", map[string]any{"conversation": "447700900114", "cursor": "wamid.GONE"}); !strings.Contains(said, "no cursor") {
		t.Fatalf("a cursor no longer in the store: %q", said)
	}
	if _, said := call("read_messages", map[string]any{"conversation": "sam"}); !strings.Contains(said, "conversation") {
		t.Fatalf("a conversation that is not a number: %q", said)
	}
}
