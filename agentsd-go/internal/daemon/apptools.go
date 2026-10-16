package daemon

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"

	acp "github.com/coder/acp-go-sdk"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// appTools is the app's own MCP server, `agents`, served on loopback with streamable HTTP
// at /mcp/agents (AppToolsEndpoint.swift). Each runtime is given a bearer token of its own,
// bound to its agent; an unknown token is a 404, as in Swift.
type appToolsEndpoint struct {
	d      *Daemon
	port   int
	mu     sync.Mutex
	tokens map[string]string // token → agent id
	// servers, one per agent, so a tool knows who calls it.
	servers map[string]*mcp.Server
}

func (d *Daemon) StartAppTools() error {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	e := &appToolsEndpoint{d: d, port: ln.Addr().(*net.TCPAddr).Port, tokens: map[string]string{}, servers: map[string]*mcp.Server{}}
	handler := mcp.NewStreamableHTTPHandler(func(r *http.Request) *mcp.Server {
		return e.serverFor(r)
	}, &mcp.StreamableHTTPOptions{JSONResponse: true})
	mux := http.NewServeMux()
	mux.Handle("/mcp/agents", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if e.agent(r) == "" {
			http.NotFound(w, r)
			return
		}
		handler.ServeHTTP(w, r)
	}))
	mux.Handle("/mcp/hosted/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if e.agent(r) == "" || d.hosted == nil {
			http.NotFound(w, r)
			return
		}
		d.hosted.ServeHTTP(w, r)
	}))
	go http.Serve(ln, mux)
	d.appTools = e.serversFor
	d.toolsPort = e.port
	log.Printf("app tools: http://127.0.0.1:%d/mcp/agents", e.port)
	return nil
}

func (e *appToolsEndpoint) agent(r *http.Request) string {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.tokens[token]
}

func (e *appToolsEndpoint) serverFor(r *http.Request) *mcp.Server {
	id := e.agent(r)
	e.mu.Lock()
	defer e.mu.Unlock()
	if s := e.servers[id]; s != nil {
		return s
	}
	s := e.d.newToolsServer(id)
	e.servers[id] = s
	return s
}

// serversFor mints a token for the agent's runtime and gives its mcpServers entries:
// `agents`, and every hosted server (stage 4) on the same port with the same bearer.
func (e *appToolsEndpoint) serversFor(agentID string) []acp.McpServer {
	token := NewUUID()
	e.mu.Lock()
	e.tokens[token] = agentID
	e.mu.Unlock()
	header := []acp.HttpHeader{{Name: "Authorization", Value: "Bearer " + token}}
	out := []acp.McpServer{{Http: &acp.McpServerHttpInline{Type: "http", Name: "agents",
		Url: fmt.Sprintf("http://127.0.0.1:%d/mcp/agents", e.port), Headers: header}}}
	if e.d.hosted != nil {
		for _, h := range e.d.hosted.routes() {
			out = append(out, acp.McpServer{Http: &acp.McpServerHttpInline{Type: "http", Name: h,
				Url: fmt.Sprintf("http://127.0.0.1:%d/mcp/hosted/%s", e.port, h), Headers: header}})
		}
	}
	return out
}

type listSessionsIn struct {
	Limit int `json:"limit,omitempty" jsonschema:"how many, newest first; 20 when left out"`
}

type readSessionIn struct {
	ID    string `json:"id" jsonschema:"the session's id, as list_sessions gave it"`
	Limit int    `json:"limit,omitempty" jsonschema:"how many of the last entries; 40 when left out"`
}

type startSessionIn struct {
	Prompt  string `json:"prompt" jsonschema:"what the new session is to do"`
	Runtime string `json:"runtime,omitempty" jsonschema:"claude or codex; the caller's own when left out"`
	Title   string `json:"title,omitempty" jsonschema:"a short title"`
}

func text(s string) *mcp.CallToolResult {
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: s}}}
}

func (d *Daemon) newToolsServer(caller string) *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{Name: "agents", Version: "0.1.0-go"}, nil)
	mcp.AddTool(s, &mcp.Tool{Name: "list_sessions", Description: "The sessions on this host: id, title, runtime, status, folder; newest first."},
		func(ctx context.Context, r *mcp.CallToolRequest, in listSessionsIn) (*mcp.CallToolResult, any, error) {
			limit := in.Limit
			if limit <= 0 {
				limit = 20
			}
			var b strings.Builder
			for i, a := range d.store.Agents() {
				if i == limit {
					break
				}
				me := ""
				if a.ID == caller {
					me = " (you)"
				}
				fmt.Fprintf(&b, "- %s: “%s”%s — %s, %s. Folder: %s\n", a.ID, a.Title, me, a.RuntimeID, a.State, folderPath(a.Cwd))
			}
			if b.Len() == 0 {
				b.WriteString("No sessions.")
			}
			return text(b.String()), nil, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "read_session", Description: "A session's conversation: the person's prompts, its replies, tool calls and how it ended. Reading changes nothing."},
		func(ctx context.Context, r *mcp.CallToolRequest, in readSessionIn) (*mcp.CallToolResult, any, error) {
			a := d.store.Agent(in.ID)
			if a == nil {
				return &mcp.CallToolResult{IsError: true, Content: []mcp.Content{&mcp.TextContent{Text: "No session " + in.ID}}}, nil, nil
			}
			limit := in.Limit
			if limit <= 0 {
				limit = 40
			}
			return text(fmt.Sprintf("“%s” — %s, %s.\n\n%s", a.Title, a.RuntimeID, a.State, readable(d.store.Transcript(a.ID), limit))), nil, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "start_session", Description: "Start a new session in the caller's folder, with a prompt. Returns its id."},
		func(ctx context.Context, r *mcp.CallToolRequest, in startSessionIn) (*mcp.CallToolResult, any, error) {
			me := d.store.Agent(caller)
			if me == nil {
				return nil, nil, fmt.Errorf("the caller is not a session on this host")
			}
			rt := in.Runtime
			if rt == "" {
				rt = me.RuntimeID
			}
			id, err := d.Start(rt, me.Cwd, in.Prompt, nil)
			if err != nil {
				return nil, nil, err
			}
			if in.Title != "" {
				a := d.store.Agent(id)
				a.Title = in.Title
				d.changed(a)
			}
			return text("Started " + id + "."), nil, nil
		})
	return s
}

// readable joins a transcript's chunks into lines a model can read.
func readable(t []Entry, limit int) string {
	var lines []string
	var cur strings.Builder
	curKind, curID := "", ""
	flush := func() {
		if cur.Len() > 0 {
			lines = append(lines, curKind+": "+cur.String())
			cur.Reset()
		}
	}
	for _, e := range t {
		for k, v := range e.Kind {
			m, _ := v.(map[string]any)
			switch k {
			case "agentMessage":
				id, _ := m["messageID"].(string)
				if curKind != "Agent" || id != curID {
					flush()
				}
				curKind, curID = "Agent", id
				s, _ := m["text"].(string)
				cur.WriteString(s)
			case "userMessage":
				flush()
				s, _ := m["_0"].(string)
				lines = append(lines, "Person: "+s)
				curKind = ""
			case "toolCall":
				flush()
				tc, _ := m["_0"].(map[string]any)
				t, _ := tc["title"].(string)
				lines = append(lines, "Tool: "+t)
				curKind = ""
			case "stateChanged":
				flush()
				s, _ := m["_0"].(string)
				if s == "finished" || s == "stopped" {
					r, _ := m["reason"].(string)
					lines = append(lines, "Ended: "+s+" ("+r+")")
				}
				curKind = ""
			}
		}
	}
	flush()
	if len(lines) > limit {
		lines = lines[len(lines)-limit:]
	}
	return strings.Join(lines, "\n")
}
