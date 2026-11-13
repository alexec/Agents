package googlechatmcp

import (
	"context"
	"io"
	"log/slog"

	"github.com/agentloops-dev/agents/Go/internal/mcpevents"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The front, as the email server's (Go/internal/emailmcp/front.go): MCP's stdio transport,
// one JSON-RPC message a line. It answers events/list and events/poll itself, and hands every
// other message to a go-sdk server with this server's tools, and that server's messages back
// as they come. MCP's SDKs have no events (a working-group draft), so the front also adds the
// `events` capability and the events' words to its answer to initialize.

// Instructions are the server's words.
const Instructions = "One Google Chat app: what people send it as events, and tools to post as it. message.received is a message to the app " +
	"(a direct message, or an @mention in a space), with its text; question.answered is a press of an option on a question that ask_question posted. " +
	"Both are raised only for a person who linked their Google Chat user, and act as that person. list_spaces lists the spaces the app is in; " +
	"send_message posts in one, in a thread when given; ask_question posts a question with a button per option. " +
	"list_conversations and read_messages read the spaces and their messages, newest first: a space's whole history when a Workspace admin " +
	"approved chat.app.messages.readonly, else only what was sent to the app and what it posted, for a day. " +
	"Everyone in a space sees what the app posts there."

// NewServer is the server behind the front: it answers initialize and ping, and has the tools,
// which read and keep e's inbox.
func NewServer(version string, e *Events) *mcp.Server {
	server := mcp.NewServer(&mcp.Implementation{Name: "googlechat-mcp", Title: "Google Chat", Version: version}, nil)
	AddTools(server, e)
	return server
}

// Front serves one client over stdio (mcpevents.Front).
type Front struct {
	Events   *Events
	Upstream *mcp.Server
	Version  string
	Logger   *slog.Logger
}

// Serve reads in until it ends and writes to out, then stops the server behind it.
func (f *Front) Serve(ctx context.Context, in io.Reader, out io.Writer) error {
	front := mcpevents.Front{Events: f.Events, List: eventsList, Upstream: f.Upstream,
		Name: "googlechat-mcp", Title: "Google Chat", Version: f.Version, Instructions: Instructions}
	return front.Serve(ctx, in, out)
}
