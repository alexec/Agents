package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/Go/wire"
)

// The Messaging slot (#1787): where agents reach the person. Slack, email and Google Chat are
// MCP servers with events and tools (#1223), not adapters, so the slot is the messaging
// connectors in the folder's or the person's mcp.json, any number of them. None is the default
// until one is there, and it counts as done; a person can skip the slot with connectors there
// too. Each connector proves itself with one real read: a tool that lists its channels,
// folders or spaces and asks for nothing, else its list of tools. The read also asks for the
// events it declares (events/list), which the slot shows. Agents writes no server of its own
// here, except the email one (#1780), which the catalogue adds.

// messagingReadTimeout is the most one connector's read takes.
const messagingReadTimeout = 20 * time.Second

// messagingReadLimit is the most connectors one read reads.
const messagingReadLimit = 6

// messagingKinds are the messaging connectors the slot knows, by what their mcp.json name or
// their command or address has in it, in the order they are looked for.
var messagingKinds = []struct {
	name  string
	marks []string
}{
	{"Slack", []string{"slack"}},
	{"Google Chat", []string{"google-chat", "googlechat", "google_chat", "gchat", "chat.google"}},
	{"WhatsApp", []string{"whatsapp"}},
	{"Microsoft Teams", []string{"msteams", "ms-teams", "microsoft-teams", "teams.microsoft"}},
	{"Discord", []string{"discord"}},
	{"Telegram", []string{"telegram"}},
	{"Email", []string{"email", "gmail", "imap", "outlook"}},
}

// messagingNouns are what a list tool's name lists, in the order one is picked.
var messagingNouns = []string{"channels", "conversations", "spaces", "chats", "rooms", "folders", "mailboxes", "labels"}

// messagingKindOf is the words for a messaging connector named name that runs as summary, and
// whether it is one.
func messagingKindOf(name, summary string) (string, bool) {
	text := strings.ToLower(name + " " + summary)
	for _, k := range messagingKinds {
		for _, m := range k.marks {
			if strings.Contains(text, m) {
				return k.name, true
			}
		}
	}
	return "", false
}

// messagingServers is the messaging connectors that reach the folder (its own mcp.json, then
// the person's), each once.
func (d *Daemon) messagingServers(folder string) []docsServerEntry {
	entries, _ := readMCPFile(filepath.Join(folder, ".agents", "mcp.json"))
	if home := d.personalHome(); home != "" {
		personal, _ := readMCPFile(filepath.Join(home, ".agents", "mcp.json"))
		entries = append(entries, personal...)
	}
	var out []docsServerEntry
	seen := map[string]bool{}
	for _, e := range entries {
		word, ok := messagingKindOf(e.name, mcpSummary(e))
		if !ok || seen[e.name] {
			continue
		}
		seen[e.name] = true
		out = append(out, docsServerEntry{e.name, word})
	}
	return out
}

// messagingDue is whether a connector that reaches the folder has no read yet.
func messagingDue(rec *slotRecord, servers []docsServerEntry) bool {
	for _, s := range servers {
		if findMessagingRecord(rec, s.name) == nil {
			return true
		}
	}
	return false
}

func findMessagingRecord(rec *slotRecord, name string) *wire.MessagingServer {
	if rec == nil {
		return nil
	}
	for i := range rec.Messaging {
		if rec.Messaging[i].Name == name {
			return &rec.Messaging[i]
		}
	}
	return nil
}

// readMessaging is the slot's read: each connector's one read, side by side, in the order of
// servers.
func (d *Daemon) readMessaging(ctx context.Context, folder string, servers []docsServerEntry, now time.Time) *slotRecord {
	secrets := d.secrets()
	out := make([]wire.MessagingServer, len(servers))
	var wg sync.WaitGroup
	for i, e := range servers {
		out[i] = wire.MessagingServer{Name: e.name, Word: e.word, State: wire.MessagingServerStateNotRead}
		if i >= messagingReadLimit {
			continue
		}
		wg.Go(func() {
			r := &out[i]
			s, cwd, err := d.docsServerFor(e.name, folder, secrets)
			var proof *wire.ConnectorProof
			var events []string
			if err == nil {
				proof, events, err = readMessagingServer(ctx, s, cwd, messagingReadTimeout)
			}
			if err != nil {
				why := err.Error()
				r.State, r.Message = wire.MessagingServerStateFailed, &why
				log.Printf("connectors: the %s messaging read failed", e.name)
				return
			}
			date := wire.DateOf(now)
			proof.At = &date
			r.State, r.Proof, r.Events = wire.MessagingServerStateRead, proof, events
		})
	}
	wg.Wait()
	return &slotRecord{Read: true, ReadAt: now, Messaging: out}
}

// messagingTool is a tool from tools/list: its name, and whether it asks for an argument.
type messagingTool struct {
	name  string
	needs bool
}

// readMessagingServer connects, lists the tools and the events, calls the tool that lists the
// server's channels, folders or spaces once with nothing, and ends: what it found.
func readMessagingServer(ctx context.Context, s sdk.McpServer, cwd string, timeout time.Duration) (*wire.ConnectorProof, []string, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var c mcpConn
	switch {
	case s.Stdio != nil:
		sc, err := startStdioMCP(s.Stdio, cwd)
		if err != nil {
			return nil, nil, docsSearchError(mcpFailureOf(err).sentence(timeout))
		}
		c = sc
	case s.Http != nil:
		c = &httpMCP{url: s.Http.Url, headers: s.Http.Headers}
	default:
		return nil, nil, docsSearchError("What came back was not MCP.")
	}
	defer c.end()
	failed := func(err error) error {
		if ctx.Err() != nil {
			err = &mcpCheckFailure{kind: "timedOut"}
		}
		return docsSearchError(mcpFailureOf(err).sentence(timeout))
	}
	raw, err := c.call(ctx, 1, "initialize", map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{},
		"clientInfo": map[string]any{"name": "Agents", "version": "1"}})
	if err != nil {
		return nil, nil, failed(err)
	}
	var init struct {
		Capabilities map[string]json.RawMessage `json:"capabilities"`
	}
	_ = json.Unmarshal(raw, &init)
	if err := c.notify(ctx, "notifications/initialized"); err != nil {
		return nil, nil, failed(err)
	}
	var tools []messagingTool
	id := 2
	for cursor := ""; ; id++ {
		params := map[string]any{}
		if cursor != "" {
			params["cursor"] = cursor
		}
		raw, err := c.call(ctx, id, "tools/list", params)
		if err != nil {
			return nil, nil, failed(err)
		}
		var page struct {
			Tools []struct {
				Name        string `json:"name"`
				InputSchema struct {
					Required []string `json:"required"`
				} `json:"inputSchema"`
			} `json:"tools"`
			NextCursor string `json:"nextCursor"`
		}
		if json.Unmarshal(raw, &page) != nil {
			return nil, nil, docsSearchError("What came back was not MCP.")
		}
		for _, t := range page.Tools {
			tools = append(tools, messagingTool{t.Name, len(t.InputSchema.Required) > 0})
		}
		if page.NextCursor == "" || id > 50 {
			break
		}
		cursor = page.NextCursor
	}
	var events []string
	if _, has := init.Capabilities["events"]; has {
		id++
		if raw, err := c.call(ctx, id, mcpEventsListMethod, map[string]any{}); err == nil {
			var list struct {
				Events []struct {
					Name string `json:"name"`
				} `json:"events"`
			}
			_ = json.Unmarshal(raw, &list)
			for _, e := range list.Events {
				events = append(events, e.Name)
			}
		}
	}
	tool, noun := messagingListTool(tools)
	if tool == "" {
		return &wire.ConnectorProof{Title: counted(len(tools), "tools")}, events, nil
	}
	raw, err = c.call(ctx, id+1, "tools/call", map[string]any{"name": tool, "arguments": map[string]any{}})
	if err != nil {
		return nil, nil, failed(err)
	}
	proof, err := messagingProof(raw, noun)
	return proof, events, err
}

// messagingListTool is the tool that lists the server's channels, folders or spaces and asks
// for nothing, and what it lists; empty when it has none.
func messagingListTool(tools []messagingTool) (name, noun string) {
	for _, n := range messagingNouns {
		for _, t := range tools {
			lower := strings.ToLower(t.name)
			if !t.needs && strings.Contains(lower, n) && (strings.Contains(lower, "list") || strings.Contains(lower, "get")) {
				return t.name, n
			}
		}
	}
	return "", ""
}

// counted is n things in words: "1 channel", "12 channels".
func counted(n int, noun string) string {
	if n == 1 {
		return "1 " + strings.TrimSuffix(noun, "s")
	}
	return fmt.Sprintf("%d %s", n, noun)
}

// messagingProof is what a list tool's result says: how many it listed, when its structured
// content or its first text is JSON with a list in it, else the first line of its text.
func messagingProof(raw json.RawMessage, noun string) (*wire.ConnectorProof, error) {
	var result struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
		Structured json.RawMessage `json:"structuredContent"`
		IsError    bool            `json:"isError"`
	}
	if json.Unmarshal(raw, &result) != nil {
		return nil, docsSearchError("What came back was not MCP.")
	}
	text := ""
	for _, c := range result.Content {
		if c.Type == "text" {
			text = strings.TrimSpace(c.Text)
			break
		}
	}
	if result.IsError {
		if text == "" {
			return nil, docsSearchError("Its list of " + noun + " failed.")
		}
		return nil, docsSearchError("It said: " + firstLine(text))
	}
	for _, body := range []json.RawMessage{result.Structured, json.RawMessage(text)} {
		if n, ok := listLength(body); ok {
			return &wire.ConnectorProof{Title: counted(n, noun)}, nil
		}
	}
	if text == "" {
		return &wire.ConnectorProof{Title: counted(0, noun)}, nil
	}
	return &wire.ConnectorProof{Title: firstLine(text)}, nil
}

// listLength is the length of the list in body: body itself, or the first list in its fields
// (in name order), one level down.
func listLength(body json.RawMessage) (int, bool) {
	if len(body) == 0 {
		return 0, false
	}
	var list []json.RawMessage
	if json.Unmarshal(body, &list) == nil {
		return len(list), true
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(body, &fields) != nil {
		return 0, false
	}
	keys := make([]string, 0, len(fields))
	for k := range fields {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	for _, k := range keys {
		if json.Unmarshal(fields[k], &list) == nil {
			return len(list), true
		}
	}
	return 0, false
}

// messagingChoice is what fills the slot, in words: its connectors' words, each once, or None.
func messagingChoice(servers []docsServerEntry) string {
	var words []string
	for _, s := range servers {
		if !slices.Contains(words, s.word) {
			words = append(words, s.word)
		}
	}
	switch len(words) {
	case 0:
		return "None"
	case 1:
		return words[0]
	}
	return strings.Join(words[:len(words)-1], ", ") + " and " + words[len(words)-1]
}

// messagingSlot is the Messaging slot from its last read. With no connector, or skipped, it
// is None (skipped, and done); its choice is None only with no connector. Else it has read when one of its connectors read, and failed
// when every one that read failed.
func messagingSlot(rec *slotRecord, skipped bool, servers []docsServerEntry) wire.ConnectorSlot {
	s := wire.ConnectorSlot{Slot: wire.ConnectorSlotKindMessaging, Choice: messagingChoice(servers)}
	for _, e := range servers {
		s.Servers = append(s.Servers, e.name)
		if r := findMessagingRecord(rec, e.name); r != nil && !skipped {
			got := *r
			got.Word = e.word
			s.MessagingServers = append(s.MessagingServers, got)
		} else {
			s.MessagingServers = append(s.MessagingServers, wire.MessagingServer{Name: e.name, Word: e.word, State: wire.MessagingServerStateNotRead})
		}
	}
	if skipped || len(servers) == 0 {
		// None: the connectors' words stay in choice, for the client's Set Up.
		s.State = wire.ConnectorSlotStateSkipped
		return s
	}
	s.State = wire.ConnectorSlotStateNotRead
	var failure *string
	tried := false
	for _, m := range s.MessagingServers {
		switch m.State {
		case wire.MessagingServerStateRead:
			s.State = wire.ConnectorSlotStateRead
			at := wire.DateOf(rec.ReadAt)
			s.ReadAt = &at
			if s.Proof == nil {
				s.Proof = m.Proof
			}
		case wire.MessagingServerStateFailed:
			tried = true
			if failure == nil {
				failure = m.Message
			}
		}
	}
	if s.State != wire.ConnectorSlotStateRead && tried {
		s.State, s.Message = wire.ConnectorSlotStateFailed, failure
	}
	return s
}
