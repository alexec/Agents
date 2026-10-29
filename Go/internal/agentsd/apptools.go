package agentsd

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// The app's own tools (mcp__agents__*), as AppToolsEndpoint and AppService serve them: one
// MCP server over loopback streamable HTTP at /mcp/agents, shared by every session, each
// session holding a token of its own in its Authorization header. The token is made when
// the runtime starts, never put in any process's environment, and taken back when the
// runtime ends; a request with a token nobody holds is a server that is not there (404).
// The tools are the Swift host's word for word (Packages/Wire/app-tools.json); a tool is
// listed once this host does what it says.

const (
	appServerName = "agents"
	appToolsPath  = "/mcp/agents"
	mcpProtocol   = "2025-06-18"
	appBodyLimit  = 16 << 20
)

type appGrant struct {
	agent       wire.UUID
	movesItself bool
	sessions    map[string]chan struct{} // Mcp-Session-Id → closed when the session ends
}

type appToolsState struct {
	appMu      sync.Mutex
	appTokens  map[string]*appGrant // token → the agent it is
	appServer  *http.Server
	appPort    int
	appStarted bool
}

// appTool is one of the tools, and what this host does when it is called.
type appTool struct {
	name string
	call func(d *Daemon, agent wire.UUID, args map[string]json.RawMessage) (string, error)
}

// appToolCalls is every tool this host does, by name. A function, as the tools reach back
// into what starts the endpoint.
func appToolCalls() []appTool {
	return []appTool{
		{"set_session_labels", (*Daemon).setSessionLabels},
		{"lease_resource", (*Daemon).leaseResource},
		{"release_resource", (*Daemon).releaseResource},
		{"list_resources", (*Daemon).listResources},
		{"wait_for_event", (*Daemon).waitForEvent},
		{"wait_for_agents", (*Daemon).waitForAgents},
		{"check_again", (*Daemon).checkAgain},
		{"cancel_wait", (*Daemon).cancelWait},
		{"show_file", (*Daemon).showFile},
		{"suggest_next_prompt", (*Daemon).suggestNextPrompt},
		{"notify", (*Daemon).notify},
		{"hang_up", (*Daemon).hangUp},
		{"ask_question", (*Daemon).askQuestion},
		{"list_sessions", (*Daemon).listSessions},
		{"read_session", (*Daemon).readSession},
		{"message_session", (*Daemon).messageSession},
		{"cancel_message", (*Daemon).cancelMessage},
		{"archive_session", (*Daemon).archiveSession},
		{"stop_session", (*Daemon).stopSession},
		{"start_session", (*Daemon).startSession},
		{"manage_workflows", (*Daemon).manageWorkflows},
		{"list_machines", (*Daemon).listMachines},
		{"start_machine", (*Daemon).startMachine},
		{"stop_machine", (*Daemon).stopMachine},
		{"make_machine", (*Daemon).makeMachine},
		{"delete_machine", (*Daemon).deleteMachine},
		{"move_worktree", (*Daemon).moveWorktree},
	}
}

// askTools put a question to a person: none on a bot's machine (#1761, FR-032).
var askTools = map[string]bool{"ask_question": true}

// startAppTools listens on loopback, once, for every session's tools.
func (d *Daemon) startAppTools() (int, error) {
	d.appMu.Lock()
	defer d.appMu.Unlock()
	if d.appStarted {
		return d.appPort, nil
	}
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	d.appServer = &http.Server{Handler: http.HandlerFunc(d.serveAppTools)}
	d.appPort = l.Addr().(*net.TCPAddr).Port
	d.appStarted = true
	srv := d.appServer
	safe.Go("app tools", func() {
		if err := srv.Serve(l); err != nil && err != http.ErrServerClosed {
			log.Printf("app tools: %v", err)
		}
	})
	return d.appPort, nil
}

func (d *Daemon) stopAppTools() {
	d.stopHosted()
	d.appMu.Lock()
	srv := d.appServer
	d.appServer = nil
	for t, g := range d.appTokens {
		g.end()
		delete(d.appTokens, t)
	}
	d.appMu.Unlock()
	if srv != nil {
		srv.Close()
	}
}

func (g *appGrant) end() {
	for id, done := range g.sessions {
		close(done)
		delete(g.sessions, id)
	}
}

// mcpServersFor is the MCP servers a session is given: the app's own, with a token made
// for this runtime, any token the agent held before taken back.
func (d *Daemon) mcpServersFor(id wire.UUID) []sdk.McpServer {
	port, err := d.startAppTools()
	if err != nil {
		log.Printf("app tools: could not listen: %v", err)
		return nil
	}
	a := d.Store.Agent(id)
	token := string(store.NewUUID())
	d.dropAppTokens(id)
	d.appMu.Lock()
	if d.appTokens == nil {
		d.appTokens = map[string]*appGrant{}
	}
	d.appTokens[token] = &appGrant{agent: id, movesItself: a != nil && runtimeCanMove(a.RuntimeID), sessions: map[string]chan struct{}{}}
	d.appMu.Unlock()
	servers := []sdk.McpServer{{Http: &sdk.McpServerHttpInline{Name: appServerName, Type: "http",
		Url:     "http://127.0.0.1:" + strconv.Itoa(port) + appToolsPath,
		Headers: []sdk.HttpHeader{{Name: "Authorization", Value: "Bearer " + token}}}}}
	// Then the folder's approved servers and the person's own (SessionServers.plan), each
	// hosted one swapped for its route on this endpoint (#488).
	if a != nil {
		servers = append(servers, d.hostedSwapped(d.sessionEntries(folderPath(a)), port, token, a.RuntimeID)...)
	}
	return servers
}

// dropAppTokens takes back every token an agent holds: its runtime has ended. A hosted
// server it used is let go when nothing else uses it.
func (d *Daemon) dropAppTokens(id wire.UUID) {
	d.appMu.Lock()
	var dropped []string
	for t, g := range d.appTokens {
		if g.agent == id {
			g.end()
			delete(d.appTokens, t)
			dropped = append(dropped, t)
		}
	}
	d.appMu.Unlock()
	for _, t := range dropped {
		d.hostedRelease(t)
	}
}

func bearer(h string) string {
	if len(h) <= 7 || !strings.EqualFold(h[:7], "bearer ") {
		return ""
	}
	return strings.TrimSpace(h[7:])
}

func loopbackOrigin(origin string) bool {
	u, err := url.Parse(origin)
	if err != nil {
		return false
	}
	switch strings.ToLower(u.Hostname()) {
	case "127.0.0.1", "localhost", "::1":
		return true
	}
	return false
}

// serveAppTools is AppToolsEndpoint.answer.
func (d *Daemon) serveAppTools(w http.ResponseWriter, r *http.Request) {
	// A page in a browser can reach loopback. Nothing here is for one.
	if o := r.Header.Get("Origin"); o != "" && !loopbackOrigin(o) {
		w.WriteHeader(http.StatusForbidden)
		return
	}
	if strings.HasPrefix(r.URL.Path, hostedPathPrefix) {
		d.serveHosted(w, r)
		return
	}
	if r.URL.Path != appToolsPath {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	token := bearer(r.Header.Get("Authorization"))
	d.appMu.Lock()
	g := d.appTokens[token]
	session := r.Header.Get("Mcp-Session-Id")
	var done chan struct{}
	if g != nil && session != "" {
		done = g.sessions[session]
	}
	d.appMu.Unlock()
	// 404, not 401, which some clients take as a cue to start signing in.
	if token == "" || g == nil || session != "" && done == nil {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	switch r.Method {
	case http.MethodPost:
		d.postAppTools(w, r, token, g, session)
	case http.MethodGet:
		if session == "" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if !strings.Contains(r.Header.Get("Accept"), "text/event-stream") {
			w.WriteHeader(http.StatusNotAcceptable)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Mcp-Session-Id", session)
		w.WriteHeader(http.StatusOK)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		// Kept as the session's event stream until it, its token or the client ends.
		select {
		case <-done:
		case <-r.Context().Done():
		case <-d.ctx.Done():
		}
	case http.MethodDelete:
		if session == "" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		d.appMu.Lock()
		if c := g.sessions[session]; c != nil {
			close(c)
			delete(g.sessions, session)
		}
		d.appMu.Unlock()
		w.WriteHeader(http.StatusOK)
	default:
		w.Header().Set("Allow", "GET, POST, DELETE")
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func (d *Daemon) postAppTools(w http.ResponseWriter, r *http.Request, token string, g *appGrant, session string) {
	body, err := io.ReadAll(io.LimitReader(r.Body, appBodyLimit+1))
	if err != nil || len(body) > appBodyLimit {
		w.WriteHeader(http.StatusRequestEntityTooLarge)
		return
	}
	var batch []json.RawMessage
	single := true
	if t := strings.TrimSpace(string(body)); strings.HasPrefix(t, "[") {
		single = false
		if json.Unmarshal(body, &batch) != nil {
			writeJSON(w, mcpFailure(nil, CodeParse, "not JSON"), "")
			return
		}
	} else {
		batch = []json.RawMessage{body}
	}
	var answers []any
	opened := ""
	for _, raw := range batch {
		var m message
		if json.Unmarshal(raw, &m) != nil {
			if single {
				writeJSON(w, mcpFailure(nil, CodeParse, "not JSON"), "")
				return
			}
			answers = append(answers, mcpFailure(nil, -32600, "not a JSON-RPC message"))
			continue
		}
		// A notification, or the client answering something: nothing to say back.
		if m.Method == "" || len(m.ID) == 0 || string(m.ID) == "null" {
			continue
		}
		result, rerr := d.appToolsHandle(r.Context(), g, m.Method, m.Params)
		if m.Method == "initialize" && rerr == nil && session == "" {
			opened = string(store.NewUUID())
			d.appMu.Lock()
			if d.appTokens[token] == g {
				g.sessions[opened] = make(chan struct{})
			}
			d.appMu.Unlock()
		}
		if rerr != nil {
			answers = append(answers, mcpFailure(m.ID, rerr.Code, rerr.Message))
		} else {
			answers = append(answers, map[string]any{"jsonrpc": "2.0", "id": m.ID, "result": result})
		}
	}
	if len(answers) == 0 {
		w.WriteHeader(http.StatusAccepted)
		return
	}
	if single {
		writeJSON(w, answers[0], opened)
	} else {
		writeJSON(w, answers, opened)
	}
}

func mcpFailure(id json.RawMessage, code int, msg string) map[string]any {
	var i any = nil
	if len(id) > 0 {
		i = id
	}
	return map[string]any{"jsonrpc": "2.0", "id": i, "error": map[string]any{"code": code, "message": msg}}
}

func writeJSON(w http.ResponseWriter, v any, session string) {
	w.Header().Set("Content-Type", "application/json")
	if session != "" {
		w.Header().Set("Mcp-Session-Id", session)
	}
	b, _ := json.Marshal(v) // Go sorts map keys, so the same tools are the same bytes
	w.WriteHeader(http.StatusOK)
	w.Write(b)
}

// offeredTools is the tools this host lists to a session: the Swift host's, those it does,
// each with the optional description AppService adds to every schema.
func offeredTools(movesItself, bot bool) []json.RawMessage {
	var all []map[string]json.RawMessage
	if err := json.Unmarshal(wire.AppTools, &all); err != nil {
		log.Printf("app tools: %v", err)
		return nil
	}
	done := map[string]bool{}
	for _, t := range appToolCalls() {
		done[t.name] = true
	}
	out := []json.RawMessage{}
	for _, t := range all {
		var name string
		json.Unmarshal(t["name"], &name)
		// A bot's machine has no ask tools: nobody answers there (#1761, FR-032).
		if !done[name] || name == "move_worktree" && !movesItself || askTools[name] && bot {
			continue
		}
		b, _ := json.Marshal(t)
		out = append(out, b)
	}
	return out
}

// appToolsHandle is AppService.handle: one MCP request.
func (d *Daemon) appToolsHandle(ctx context.Context, g *appGrant, method string, params json.RawMessage) (any, *Error) {
	switch method {
	case "initialize":
		var p struct {
			ProtocolVersion string `json:"protocolVersion"`
		}
		json.Unmarshal(params, &p)
		version := p.ProtocolVersion
		if version == "" {
			version = mcpProtocol
		}
		return map[string]any{"protocolVersion": version,
			"capabilities": map[string]any{"tools": map[string]any{"listChanged": false}, "resources": map[string]any{"listChanged": false}},
			"serverInfo":   map[string]any{"name": appServerName, "version": "1.0.0"}}, nil
	case "ping":
		return map[string]any{}, nil
	case "tools/list":
		return map[string]any{"tools": offeredTools(g.movesItself, d.isBot())}, nil
	case "resources/list":
		return map[string]any{"resources": []any{}}, nil
	case "resources/read":
		var p struct {
			URI string `json:"uri"`
		}
		json.Unmarshal(params, &p)
		return nil, Invalid("No resource at %s.", p.URI)
	case "tools/call":
		var p struct {
			Name      string                     `json:"name"`
			Arguments map[string]json.RawMessage `json:"arguments"`
		}
		json.Unmarshal(params, &p)
		// Matched by the end of the name: a runtime is free to put its own prefix on it.
		var tool *appTool
		calls := appToolCalls()
		for i := range calls {
			if strings.HasSuffix(p.Name, calls[i].name) && (tool == nil || len(calls[i].name) > len(tool.name)) {
				tool = &calls[i]
			}
		}
		if tool == nil {
			name := p.Name
			if name == "" {
				name = "that"
			}
			return nil, Invalid("No tool called %s.", name)
		}
		if askTools[tool.name] && d.isBot() {
			return toolReply(noOneAnswersWords, true), nil
		}
		began := time.Now()
		note, err := tool.call(d, g.agent, p.Arguments)
		d.keepAppToolCall(g.agent, tool.name, p.Arguments, note, err, began)
		if err != nil {
			msg := err.Error()
			if e, ok := err.(*Error); ok {
				msg = e.Message
			}
			return toolReply(msg, true), nil
		}
		return toolReply(note, false), nil
	}
	return nil, &Error{Code: CodeMethodNotFound, Message: "method not found: " + method}
}

func toolReply(text string, isError bool) map[string]any {
	return map[string]any{"content": []any{map[string]any{"type": "text", "text": text}}, "isError": isError}
}

// stringList is AppService's strings(_:): one string or a list of them.
func stringList(args map[string]json.RawMessage, key string) ([]string, error) {
	raw, ok := args[key]
	if !ok || string(raw) == "null" {
		return nil, nil
	}
	var one string
	if json.Unmarshal(raw, &one) == nil {
		return []string{one}, nil
	}
	var list []string
	if json.Unmarshal(raw, &list) != nil {
		return nil, Invalid("Nothing changed: `%s` must be a list of strings.", key)
	}
	return list, nil
}

// setSessionLabels is set_session_labels: the agent's own labels, changed now.
func (d *Daemon) setSessionLabels(id wire.UUID, args map[string]json.RawMessage) (string, error) {
	add, err := stringList(args, "add")
	if err != nil {
		return "", err
	}
	remove, err := stringList(args, "remove")
	if err != nil {
		return "", err
	}
	if len(add) == 0 && len(remove) == 0 {
		return "", Invalid("Nothing changed: give labels in add, remove, or both.")
	}
	a := d.Store.Agent(id)
	if a == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was changed."}
	}
	labels, err := changeLabelsAs(wire.SessionLabelOwnerAgent, a.Labels, add, remove, vocabulary(folderPath(a), d.Store.Agents()))
	if err != nil {
		msg := err.Error()
		if e, ok := err.(*Error); ok {
			msg = e.Message
		}
		return "", Invalid("Nothing changed: %s", msg)
	}
	got := d.change(id, func(a *wire.Agent) { a.Labels = labels })
	if got == nil || len(got.Labels) == 0 {
		return "This session has no labels now.", nil
	}
	var values []string
	for _, l := range got.Labels {
		values = append(values, l.Value)
	}
	return "This session's labels: " + strings.Join(values, ", ") + ".", nil
}
