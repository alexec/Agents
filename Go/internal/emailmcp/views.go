package emailmcp

import (
	"context"
	"embed"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The email server's view (#1780): Mail (ui://email/mail), an MCP App page (SEP-1865) the
// Agents host draws on the Mac, the Remote and the web page, in the shape of the linear
// server's (Go/internal/linearmcp/views.go). show_mail feeds it, a read-only tool, so it can
// be pinned: the folders, and a folder's newest messages. The page reads a message with
// read_message and shows its text as plain text, marked as outside content; Mark Read and
// Move call mark_read and move_message. Nothing on it sends mail.

// pages/bridge.js and pages/common.css are the github server's, copied: a page has no
// network, so it carries its own.
//
//go:embed pages
var pageFiles embed.FS

const (
	viewMime = "text/html;profile=mcp-app"
	mailURI  = "ui://email/mail"
)

func page(name string) string {
	read := func(n string) string {
		b, err := pageFiles.ReadFile("pages/" + n)
		if err != nil {
			panic(err)
		}
		return string(b)
	}
	return strings.NewReplacer("/*common.css*/", read("common.css"), "/*bridge.js*/", read("bridge.js")).Replace(read(name))
}

func uiMeta(uri string, visibility ...string) mcp.Meta {
	return mcp.Meta{"ui": map[string]any{"visibility": visibility, "resourceUri": uri}, "ui/resourceUri": uri}
}

// visibility says who may call a tool: the agent ("model"), a page ("app"), or both.
func visibility(v ...string) mcp.Meta { return mcp.Meta{"ui": map[string]any{"visibility": v}} }

type showArgs struct {
	Folder     string `json:"folder,omitempty" jsonschema:"the folder; INBOX when left out"`
	UnreadOnly bool   `json:"unreadOnly,omitempty" jsonschema:"true: only unread messages"`
}

// addViews puts show_mail and the Mail page on server.
func addViews(server *mcp.Server, m *Mailbox) {
	tool(server, &mcp.Tool{Name: "show_mail", Title: "Show mail",
		Description: "The mailbox's folders with their unread counts, and a folder's 50 newest messages (INBOX unless folder says), " +
			"without their text. Its view is the Mail page: the person picks a message there to read it.",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true}, Meta: uiMeta(mailURI, "model", "app")},
		func(ctx context.Context, in showArgs) (*mcp.CallToolResult, error) {
			folder := folderOr(in.Folder)
			folders, err := m.Folders(ctx)
			if err != nil {
				return nil, err
			}
			list, err := m.List(ctx, folder, in.UnreadOnly, 50)
			if err != nil {
				return nil, err
			}
			names := make([]any, len(folders))
			for i, f := range folders {
				names[i] = map[string]any{"name": f.Name, "role": f.Role, "total": f.Total, "unread": f.Unread}
			}
			return structured(map[string]any{"folder": folder, "unreadOnly": in.UnreadOnly, "folders": names,
				"messages": summaries(list)}), nil
		})

	// No network at all: an empty csp, so the host draws it under its strictest policy.
	meta := mcp.Meta{"ui": map[string]any{"csp": map[string]any{}, "prefersBorder": true}}
	html := page("mail.html")
	server.AddResource(&mcp.Resource{URI: mailURI, Name: "mail", Title: "Mail",
		Description: "The mailbox: its folders, a folder's newest messages, and a message's text, marked as outside content. " +
			"Mark Read and Move on each message. Fed by show_mail.", MIMEType: viewMime, Meta: meta},
		func(context.Context, *mcp.ReadResourceRequest) (*mcp.ReadResourceResult, error) {
			return &mcp.ReadResourceResult{Contents: []*mcp.ResourceContents{{URI: mailURI, MIMEType: viewMime, Text: html, Meta: meta}}}, nil
		})
}
