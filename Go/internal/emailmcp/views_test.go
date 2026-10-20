package emailmcp

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The Mail page (#1780) over the fake mailbox, through an MCP client: what show_mail gives
// the page, who may call what, and the page itself.

func viewsClient(t *testing.T, m *Mailbox) *mcp.ClientSession {
	t.Helper()
	server := NewServer("test", m)
	ct, st := mcp.NewInMemoryTransports()
	ctx := context.Background()
	if _, err := server.Connect(ctx, st, nil); err != nil {
		t.Fatal(err)
	}
	c, err := mcp.NewClient(&mcp.Implementation{Name: "test"}, nil).Connect(ctx, ct, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

func callTool(t *testing.T, c *mcp.ClientSession, name string, args map[string]any) map[string]any {
	t.Helper()
	r, err := c.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	if r.IsError {
		t.Fatalf("%s: %v", name, r.Content[0].(*mcp.TextContent).Text)
	}
	var data map[string]any
	b, _ := json.Marshal(r.StructuredContent)
	_ = json.Unmarshal(b, &data)
	return data
}

func TestShowMailGivesTheFoldersAndAFoldersNewest(t *testing.T) {
	f := newFakeMail(t, nil)
	f.deliver("INBOX", plain("GitLab <gitlab@mg.gitlab.com>", fakeUser, "Your sign-in code", "Your code is 482913."))
	f.deliver("Archive", plain("a@example.com", fakeUser, "Old", "old"))
	c := viewsClient(t, f.mailbox())

	data := callTool(t, c, "show_mail", map[string]any{})
	folders, _ := data["folders"].([]any)
	messages, _ := data["messages"].([]any)
	if data["folder"] != "INBOX" || len(folders) != 2 || len(messages) != 1 {
		t.Fatalf("show_mail: %v", data)
	}
	first := messages[0].(map[string]any)
	if first["subject"] != "Your sign-in code" || first["unread"] != true {
		t.Fatalf("message: %v", first)
	}
	if _, ok := first["body"]; ok {
		t.Fatal("the list carries a message's text")
	}
	archive := callTool(t, c, "show_mail", map[string]any{"folder": "Archive"})
	if archive["folder"] != "Archive" || len(archive["messages"].([]any)) != 1 {
		t.Fatalf("Archive: %v", archive)
	}
	if none := callTool(t, c, "show_mail", map[string]any{"unreadOnly": true, "folder": "Archive"}); len(none["messages"].([]any)) != 1 {
		t.Fatalf("unread only: %v", none)
	}
}

// The page may call the tools it uses; show_mail names the page.
func TestThePageMayCallWhatItUses(t *testing.T) {
	f := newFakeMail(t, nil)
	c := viewsClient(t, f.mailbox())
	tools, err := c.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, tl := range tools.Tools {
		ui, _ := tl.Meta["ui"].(map[string]any)
		vis, _ := ui["visibility"].([]any)
		app := false
		for _, v := range vis {
			app = app || v == "app"
		}
		seen[tl.Name] = app
		if tl.Name == "show_mail" && ui["resourceUri"] != mailURI {
			t.Fatalf("show_mail's page: %v", tl.Meta)
		}
	}
	for _, name := range []string{"show_mail", "read_message", "mark_read", "move_message", "list_folders"} {
		if !seen[name] {
			t.Errorf("the page may not call %s", name)
		}
	}
}

func TestThePageIsWholeAndDrawsTheTextAsText(t *testing.T) {
	f := newFakeMail(t, nil)
	c := viewsClient(t, f.mailbox())
	r, err := c.ReadResource(context.Background(), &mcp.ReadResourceParams{URI: mailURI})
	if err != nil {
		t.Fatal(err)
	}
	html := r.Contents[0].Text
	if r.Contents[0].MIMEType != viewMime || !strings.Contains(html, "const bridge") ||
		strings.Contains(html, "/*common.css*/") || strings.Contains(html, "/*bridge.js*/") {
		t.Fatalf("page: %.200s", html)
	}
	// The mail's text never becomes markup on the page.
	if strings.Contains(html, "innerHTML") || strings.Contains(html, "insertAdjacentHTML") || strings.Contains(html, "document.write") {
		t.Fatal("the page writes markup")
	}
	if !strings.Contains(html, "Outside content") {
		t.Fatal("the page does not say the text is outside content")
	}
}

// The bridge and the styles are the github server's, word for word: one host draws both.
func TestThePageSharesTheGitHubServersBridge(t *testing.T) {
	for _, name := range []string{"bridge.js", "common.css"} {
		ours, err := pageFiles.ReadFile("pages/" + name)
		if err != nil {
			t.Fatal(err)
		}
		theirs, err := os.ReadFile("../githubmcp/pages/" + name)
		if err != nil {
			t.Fatal(err)
		}
		if string(ours) != string(theirs) {
			t.Errorf("%s is not the github server's", name)
		}
	}
}
