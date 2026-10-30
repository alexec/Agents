package agentsd

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"hash/fnv"
	"io"
	"log"
	"math"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/githubmcp"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// MCP servers the host runs (#488), as HostedMCPServers does on the Swift host: one copy
// per host of an mcp.json stdio entry with "hosted": true, shared by every session.
//
//   - One process per entry, in a process group of its own, with the environment and
//     secrets a session would give it. Ended with the host.
//   - Served on the app's loopback endpoint at /mcp/hosted/<route>, each session's token as
//     the bearer. A runtime is handed it as an http server.
//   - Many clients, one server: the host is the server's one client. It initializes the
//     server once and answers each client's initialize with what the server said (with the
//     protocol version the client asked for); requests go through with ids of the host's
//     own. A client's notifications stop here.
//   - Idles like a session: in use while a session holding its route is open. When the last
//     one ends the process is let go; the next call starts it again.
//   - Restarted with backoff when it stops while in use: 1 s, 2 s, 4 s … up to a minute,
//     back to 1 s once it has run a minute.
//   - stderr to mcp-logs/<name>-<scope digest>.log in the log folder, rolled at 1 MB. The
//     status keeps its last line.
//
// Logged: the server's name and a word, never its command, arguments, environment or any
// body (054 FR-023). Views go through this copy too (hostedviews.go, #1341); event
// subscriptions still run their own copy on this host.

const (
	hostedLimit      = 8
	hostedPathPrefix = "/mcp/hosted/"
	hostedLogLimit   = 1 << 20
)

var (
	hostedCallTimeout  = 300 * time.Second
	hostedStartTimeout = 60 * time.Second
	hostedBackoffMax   = 60 * time.Second
	hostedSteadyAfter  = 60 * time.Second
	hostedKillAfter    = 2 * time.Second
	errHostedTooMany   = errors.New("too many hosted servers in use")
)

// hostedKey is MCPClientPool.Key: the file's scope ("~" for the person's own), the
// server's name, and its entry as filled.
type hostedKey struct{ scope, name, entry string }

type hostedStart struct {
	done   chan struct{}
	result json.RawMessage
	err    *Error
}

type hostedServer struct {
	key    hostedKey
	route  string
	folder *string
	server sdk.McpServerStdio
	cwd    string
	users  map[string]bool
	// MCP sessions opened by clients, kept across restarts.
	sessions map[string]bool
	state    wire.HostedMCPState
	cmd      *exec.Cmd
	in       io.WriteCloser
	// Which start the process is: an exit from an older one is not this one's.
	generation  int
	starting    *hostedStart
	initialized json.RawMessage
	waiting     map[string]chan json.RawMessage
	since       *time.Time
	retryAt     *time.Time
	retry       *time.Timer
	lastError   string
	lastStderr  string
	restarts    int
	failures    int
	log         *hostedLog
	// viewOnly are the tools only a view may call, as its tools/list last said (#1341).
	viewOnly map[string]bool
}

type hostedPool struct {
	hostedMu      sync.Mutex
	hostedByKey   map[hostedKey]*hostedServer
	hostedByRoute map[string]*hostedServer
	hostedNextID  int
	hostedStopped bool
	hostedTell    chan struct{}
	// hostedViewTimers end views' use of a copy, viewLinger after their last request.
	hostedViewTimers map[string]*time.Timer
}

func (d *Daemon) registerHostedMCP() {
	On(d, wire.CallMCPHosted, func(context.Context, *Client, wire.Empty) (wire.HostedMCPSnapshot, error) {
		return d.hostedSnapshot(), nil
	})
}

// hostedChangedLocked says mcp/hostedChanged, and has the MCP Servers pages look again
// (#753). One sender, so a later snapshot is never overtaken by an earlier one.
func (d *Daemon) hostedChangedLocked() {
	if d.hostedTell == nil {
		d.hostedTell = make(chan struct{}, 1)
		tell := d.hostedTell
		safe.Go("hosted mcp", func() {
			for {
				select {
				case <-tell:
					Broadcast(d, wire.NotifyMCPHostedChanged, d.hostedSnapshot())
					d.mcpChanged()
				case <-d.ctx.Done():
					return
				}
			}
		})
	}
	select {
	case d.hostedTell <- struct{}{}:
	default:
	}
}

func (h *hostedServer) status() wire.HostedMCPStatus {
	s := wire.HostedMCPStatus{Name: h.key.name, Folder: h.folder, State: h.state,
		Restarts: int64(h.restarts), Users: int64(len(h.users))}
	if h.state == "" {
		s.State = wire.HostedMCPStateIdle
	}
	if h.since != nil {
		at := wire.DateOf(*h.since)
		s.Since = &at
	}
	if h.retryAt != nil {
		at := wire.DateOf(*h.retryAt)
		s.RetryAt = &at
	}
	if h.lastError != "" {
		e := h.lastError
		s.LastError = &e
	}
	return s
}

func (d *Daemon) hostedSnapshot() wire.HostedMCPSnapshot {
	d.hostedMu.Lock()
	servers := make([]wire.HostedMCPStatus, 0, len(d.hostedByKey))
	for _, h := range d.hostedByKey {
		servers = append(servers, h.status())
	}
	d.hostedMu.Unlock()
	sort.Slice(servers, func(i, j int) bool {
		pi, pj := "", ""
		if servers[i].Folder != nil {
			pi = *servers[i].Folder
		}
		if servers[j].Folder != nil {
			pj = *servers[j].Folder
		}
		if pi != pj {
			return pi < pj
		}
		return servers[i].Name < servers[j].Name
	})
	return wire.HostedMCPSnapshot{Servers: servers, At: now()}
}

// hostedStatus is the health row's live state: the one in use, else any.
func (d *Daemon) hostedStatus(folder *string, name string) *wire.HostedMCPStatus {
	scope := "~"
	if folder != nil {
		scope = *folder
	}
	d.hostedMu.Lock()
	defer d.hostedMu.Unlock()
	var found *hostedServer
	for k, h := range d.hostedByKey {
		if k.scope == scope && k.name == name && (found == nil || len(h.users) > len(found.users)) {
			found = h
		}
	}
	if found == nil {
		return nil
	}
	s := found.status()
	return &s
}

// MARK: users

// hostedUse is HostedMCPServers.use: user (a session's token) uses server; the path it is
// served at. Nothing starts until the first call.
func (d *Daemon) hostedUse(server sdk.McpServerStdio, folder *string, cwd, user string) (string, error) {
	scope := "~"
	if folder != nil {
		scope = *folder
	}
	key := hostedKey{scope: scope, name: server.Name, entry: serverDigest(sdk.McpServer{Stdio: &server})}
	d.hostedMu.Lock()
	defer d.hostedMu.Unlock()
	if d.hostedByKey == nil {
		d.hostedByKey, d.hostedByRoute = map[hostedKey]*hostedServer{}, map[string]*hostedServer{}
	}
	if h := d.hostedByKey[key]; h != nil {
		if len(h.users) == 0 && d.hostedInUseLocked() >= hostedLimit {
			return "", errHostedTooMany
		}
		h.server, h.cwd = server, cwd
		if !h.users[user] {
			h.users[user] = true
			d.hostedChangedLocked()
		}
		return hostedPathPrefix + h.route, nil
	}
	if d.hostedInUseLocked() >= hostedLimit {
		return "", errHostedTooMany
	}
	// The same server under an entry since changed, unused: forgotten (bound data).
	for k, h := range d.hostedByKey {
		if k.scope == key.scope && k.name == key.name && len(h.users) == 0 {
			delete(d.hostedByKey, k)
			delete(d.hostedByRoute, h.route)
		}
	}
	route := strings.ToLower(strings.ReplaceAll(string(store.NewUUID()), "-", ""))
	h := &hostedServer{key: key, route: route, folder: folder, server: server, cwd: cwd,
		users: map[string]bool{user: true}, sessions: map[string]bool{}, state: wire.HostedMCPStateIdle,
		waiting: map[string]chan json.RawMessage{}}
	d.hostedByKey[key] = h
	d.hostedByRoute[route] = h
	d.hostedChangedLocked()
	return hostedPathPrefix + route, nil
}

func (d *Daemon) hostedInUseLocked() int {
	n := 0
	for _, h := range d.hostedByKey {
		if len(h.users) > 0 {
			n++
		}
	}
	return n
}

// hostedRelease is release: user is over. A server nobody uses is let go.
func (d *Daemon) hostedRelease(user string) {
	d.hostedMu.Lock()
	defer d.hostedMu.Unlock()
	for _, h := range d.hostedByKey {
		if h.users[user] {
			delete(h.users, user)
			if len(h.users) == 0 {
				d.hostedIdleLocked(h)
			}
			d.hostedChangedLocked()
		}
	}
}

// stopHosted ends every server: the host is stopping.
func (d *Daemon) stopHosted() {
	d.hostedMu.Lock()
	defer d.hostedMu.Unlock()
	d.hostedStopped = true
	for _, h := range d.hostedByKey {
		h.users = map[string]bool{}
		d.hostedIdleLocked(h)
	}
}

// hostedSwapped is a session's servers with each hosted one swapped for its route, the
// session's token as the bearer. One the host has no room for goes as it is, so the
// runtime runs its own copy: the agent still has its tools, but not the person-only ones,
// which only the host's copy has (githubmcp.HostedEnv is never in a session's copy).
func (d *Daemon) hostedSwapped(entries []sessionEntry, port int, token, runtimeID string) []sdk.McpServer {
	out := make([]sdk.McpServer, 0, len(entries))
	for _, e := range entries {
		if !e.hosted || e.server.Stdio == nil || token == "" {
			out = append(out, withoutHostedEnv(e.server))
			continue
		}
		path, err := d.hostedUse(*e.server.Stdio, e.folder, e.cwd, token)
		if err != nil {
			log.Printf("hosted mcp: %s runs in the %s session itself, without its view-only tools: %d hosted servers are in use", e.name, runtimeID, hostedLimit)
			out = append(out, withoutHostedEnv(e.server))
			continue
		}
		out = append(out, sdk.McpServer{Http: &sdk.McpServerHttpInline{Name: e.name, Type: "http",
			Url:     "http://127.0.0.1:" + strconv.Itoa(port) + path,
			Headers: []sdk.HttpHeader{{Name: "Authorization", Value: "Bearer " + token}}}})
	}
	return out
}

// withoutHostedEnv is a stdio server without githubmcp.HostedEnv in its environment: a
// session's own copy is never the host's.
func withoutHostedEnv(s sdk.McpServer) sdk.McpServer {
	if s.Stdio == nil {
		return s
	}
	stdio := *s.Stdio
	stdio.Env = make([]sdk.EnvVariable, 0, len(s.Stdio.Env))
	for _, e := range s.Stdio.Env {
		if e.Name != githubmcp.HostedEnv {
			stdio.Env = append(stdio.Env, e)
		}
	}
	s.Stdio = &stdio
	return s
}

// MARK: http

// serveHosted is answer: one request to /mcp/hosted/<route>. A token that does not use the
// route, or a session it does not know, is 404: a server that is not there.
func (d *Daemon) serveHosted(w http.ResponseWriter, r *http.Request) {
	route := strings.TrimPrefix(r.URL.Path, hostedPathPrefix)
	token := bearer(r.Header.Get("Authorization"))
	session := r.Header.Get("Mcp-Session-Id")
	d.hostedMu.Lock()
	h := d.hostedByRoute[route]
	known := token != "" && h != nil && h.users[token] && (session == "" || h.sessions[session])
	d.hostedMu.Unlock()
	if !known {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	switch r.Method {
	case http.MethodPost:
		d.postHosted(w, r, h, session)
	case http.MethodDelete:
		if session == "" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		d.hostedMu.Lock()
		delete(h.sessions, session)
		d.hostedMu.Unlock()
		w.WriteHeader(http.StatusOK)
	default:
		// No stream: what the server says first does not reach a client.
		w.Header().Set("Allow", "POST, DELETE")
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func (d *Daemon) postHosted(w http.ResponseWriter, r *http.Request, h *hostedServer, session string) {
	body, err := io.ReadAll(io.LimitReader(r.Body, appBodyLimit+1))
	if err != nil || len(body) > appBodyLimit {
		w.WriteHeader(http.StatusRequestEntityTooLarge)
		return
	}
	var batch []json.RawMessage
	single := true
	if t := bytes.TrimSpace(body); len(t) > 0 && t[0] == '[' {
		single = false
		if json.Unmarshal(body, &batch) != nil {
			writeJSON(w, mcpFailure(nil, CodeParse, "not JSON"), "")
			return
		}
	} else {
		if !json.Valid(body) {
			writeJSON(w, mcpFailure(nil, CodeParse, "not JSON"), "")
			return
		}
		batch = []json.RawMessage{body}
	}
	var answers []any
	opened := ""
	for _, raw := range batch {
		var m message
		if json.Unmarshal(raw, &m) != nil {
			answers = append(answers, mcpFailure(nil, -32600, "not a JSON-RPC message"))
			continue
		}
		// A notification, or the client answering something: it stops here.
		if m.Method == "" || len(m.ID) == 0 || string(m.ID) == "null" {
			continue
		}
		result, rerr := d.hostedSessionCall(h, m.Method, m.Params)
		if rerr != nil {
			answers = append(answers, mcpFailure(m.ID, rerr.Code, rerr.Message))
			continue
		}
		if m.Method == "initialize" {
			result = withProtocolVersion(result, m.Params)
			if session == "" {
				opened = string(store.NewUUID())
				d.hostedMu.Lock()
				h.sessions[opened] = true
				d.hostedMu.Unlock()
			}
		}
		answers = append(answers, map[string]any{"jsonrpc": "2.0", "id": m.ID, "result": result})
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

// withProtocolVersion is the server's initialize result with the version the client asked
// for, when it asked for one.
func withProtocolVersion(result, params json.RawMessage) json.RawMessage {
	var asked struct {
		ProtocolVersion string `json:"protocolVersion"`
	}
	var shape map[string]json.RawMessage
	if json.Unmarshal(params, &asked) != nil || asked.ProtocolVersion == "" || json.Unmarshal(result, &shape) != nil || shape == nil {
		return result
	}
	shape["protocolVersion"], _ = json.Marshal(asked.ProtocolVersion)
	b, _ := json.Marshal(shape)
	return b
}

// hostedCall is one request to the server, started first when it is not running.
func (d *Daemon) hostedCall(h *hostedServer, method string, params json.RawMessage) (json.RawMessage, *Error) {
	initialized, err := d.hostedReady(h)
	if err != nil {
		return nil, err
	}
	switch method {
	case "initialize":
		return initialized, nil
	case "ping":
		return json.RawMessage(`{}`), nil
	}
	return d.hostedSend(h, method, params, hostedCallTimeout)
}

// MARK: the process

func hostedFailure(msg string) *Error { return &Error{Code: -32000, Message: msg} }

// hostedReady is the server's initialize result, starting it first if need be.
func (d *Daemon) hostedReady(h *hostedServer) (json.RawMessage, *Error) {
	d.hostedMu.Lock()
	if h.state == wire.HostedMCPStateRunning && h.initialized != nil {
		r := h.initialized
		d.hostedMu.Unlock()
		return r, nil
	}
	if s := h.starting; s != nil {
		d.hostedMu.Unlock()
		<-s.done
		return s.result, s.err
	}
	if h.state == wire.HostedMCPStateRestarting {
		msg := h.key.name + " is restarting"
		if h.lastError != "" {
			msg += ": " + h.lastError
		} else {
			msg += "."
		}
		d.hostedMu.Unlock()
		return nil, hostedFailure(msg)
	}
	if d.hostedStopped {
		d.hostedMu.Unlock()
		return nil, hostedFailure("The app is stopping.")
	}
	s := &hostedStart{done: make(chan struct{})}
	h.starting = s
	d.hostedMu.Unlock()
	s.result, s.err = d.hostedStart(h)
	d.hostedMu.Lock()
	h.starting = nil
	d.hostedMu.Unlock()
	close(s.done)
	return s.result, s.err
}

func (d *Daemon) hostedStart(h *hostedServer) (json.RawMessage, *Error) {
	d.hostedMu.Lock()
	h.generation++
	generation := h.generation
	h.state = wire.HostedMCPStateStarting
	h.initialized = nil
	d.hostedChangedLocked()
	s := h.server
	cmd := loginCommand(mcpServerEnvironment(), s.Command, s.Args...)
	cmd.Dir = h.cwd
	for _, e := range s.Env {
		cmd.Env = append(cmd.Env, e.Name+"="+e.Value)
	}
	// Only this copy has a server's person-only tools (githubmcp.HostedEnv).
	cmd.Env = append(cmd.Env, githubmcp.HostedEnv+"=1")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Stderr = &hostedStderr{d: d, h: h, log: d.hostedLogLocked(h)}
	in, inErr := cmd.StdinPipe()
	out, outErr := cmd.StdoutPipe()
	var err error
	if err = errors.Join(inErr, outErr); err == nil {
		err = cmd.Start()
	}
	if err != nil {
		why := "It could not be started."
		if errors.Is(err, exec.ErrNotFound) {
			why = "The command was not found."
		}
		log.Printf("hosted mcp: %s could not start", h.key.name)
		d.hostedStoppedLocked(h, why)
		d.hostedMu.Unlock()
		return nil, hostedFailure(h.key.name + " could not be started.")
	}
	h.cmd, h.in = cmd, in
	log.Printf("hosted mcp: %s started (pid %d)", h.key.name, cmd.Process.Pid)
	d.hostedMu.Unlock()
	safe.Go("hosted mcp", func() {
		r := bufio.NewReaderSize(out, 64*1024)
		for {
			line, err := r.ReadBytes('\n')
			if len(bytes.TrimSpace(line)) > 0 {
				d.hostedHeard(h, generation, line)
			}
			if err != nil {
				break
			}
		}
		code := 0
		if err := cmd.Wait(); err != nil {
			code = -1
			var exit *exec.ExitError
			if errors.As(err, &exit) {
				code = exit.ExitCode()
			}
		}
		d.hostedExited(h, generation, code)
	})
	params, _ := json.Marshal(map[string]any{"protocolVersion": mcpProtocol, "capabilities": map[string]any{},
		"clientInfo": map[string]any{"name": "Agents", "version": "1"}})
	result, rerr := d.hostedSend(h, "initialize", params, hostedStartTimeout)
	d.hostedMu.Lock()
	defer d.hostedMu.Unlock()
	if rerr == nil && h.generation == generation {
		d.hostedWriteLocked(h, map[string]any{"jsonrpc": "2.0", "method": "notifications/initialized"})
		at := nowFunc()
		h.initialized, h.state, h.since, h.retryAt = result, wire.HostedMCPStateRunning, &at, nil
		d.hostedChangedLocked()
		return result, nil
	}
	if rerr == nil {
		return nil, hostedFailure(h.key.name + " stopped as it started.")
	}
	if h.generation == generation && h.state == wire.HostedMCPStateStarting {
		hostedEnd(h.cmd, h.in)
		h.generation++
		d.hostedStoppedLocked(h, "It did not answer initialize: "+rerr.Message)
	}
	return nil, rerr
}

// hostedSend sends one request with an id of the host's own, and waits for its answer.
func (d *Daemon) hostedSend(h *hostedServer, method string, params json.RawMessage, timeout time.Duration) (json.RawMessage, *Error) {
	d.hostedMu.Lock()
	if h.cmd == nil {
		d.hostedMu.Unlock()
		return nil, hostedFailure(h.key.name + " is not running.")
	}
	// A number of the host's own: some servers take no other kind of id.
	d.hostedNextID++
	id := strconv.Itoa(d.hostedNextID)
	m := map[string]any{"jsonrpc": "2.0", "id": d.hostedNextID, "method": method}
	if len(params) > 0 {
		m["params"] = params
	}
	answer := make(chan json.RawMessage, 1)
	h.waiting[id] = answer
	if !d.hostedWriteLocked(h, m) {
		delete(h.waiting, id)
		msg := h.lastError
		if msg == "" {
			msg = h.key.name + " stopped."
		}
		d.hostedMu.Unlock()
		return nil, hostedFailure(msg)
	}
	d.hostedMu.Unlock()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	var raw json.RawMessage
	select {
	case raw = <-answer:
	case <-timer.C:
		d.hostedMu.Lock()
		delete(h.waiting, id)
		d.hostedMu.Unlock()
		return nil, &Error{Code: -32001, Message: h.key.name + " did not answer in time."}
	}
	var reply struct {
		Result json.RawMessage `json:"result"`
		Error  *struct {
			Code    *int    `json:"code"`
			Message *string `json:"message"`
		} `json:"error"`
	}
	json.Unmarshal(raw, &reply)
	if reply.Error != nil {
		e := &Error{Code: -32000, Message: "The server refused."}
		if reply.Error.Code != nil {
			e.Code = *reply.Error.Code
		}
		if reply.Error.Message != nil {
			e.Message = *reply.Error.Message
		}
		return nil, e
	}
	if len(reply.Result) == 0 {
		return json.RawMessage("null"), nil
	}
	return reply.Result, nil
}

func hostedAnswer(code int, msg string) json.RawMessage {
	b, _ := json.Marshal(map[string]any{"error": map[string]any{"code": code, "message": msg}})
	return b
}

func (d *Daemon) hostedWriteLocked(h *hostedServer, m any) bool {
	if h.in == nil {
		return false
	}
	b, err := json.Marshal(m)
	if err != nil {
		return false
	}
	_, err = h.in.Write(append(b, '\n'))
	return err == nil
}

func (d *Daemon) hostedHeard(h *hostedServer, generation int, line []byte) {
	var m struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
	}
	if json.Unmarshal(line, &m) != nil {
		return
	}
	d.hostedMu.Lock()
	defer d.hostedMu.Unlock()
	if h.generation != generation {
		return
	}
	if m.Method != "" {
		// The server asking something of its client: told no, so it does not wait.
		if len(m.ID) > 0 && string(m.ID) != "null" {
			d.hostedWriteLocked(h, map[string]any{"jsonrpc": "2.0", "id": m.ID,
				"error": map[string]any{"code": CodeMethodNotFound, "message": "Not passed on by the app."}})
		}
		return
	}
	if answer := h.waiting[string(bytes.TrimSpace(m.ID))]; answer != nil {
		id := string(bytes.TrimSpace(m.ID))
		delete(h.waiting, id)
		answer <- append(json.RawMessage(nil), line...)
	}
}

func (d *Daemon) hostedExited(h *hostedServer, generation, code int) {
	d.hostedMu.Lock()
	defer d.hostedMu.Unlock()
	if h.generation != generation {
		return
	}
	h.cmd, h.in, h.initialized = nil, nil, nil
	why := "It stopped (exit code " + strconv.Itoa(code) + ")."
	if code == 127 {
		why = "The command was not found."
	}
	d.hostedFailWaitingLocked(h, hostedAnswer(-32000, h.key.name+" stopped: "+why))
	if h.state == wire.HostedMCPStateIdle {
		return
	}
	log.Printf("hosted mcp: %s stopped (exit %d)", h.key.name, code)
	d.hostedStoppedLocked(h, why)
}

func (d *Daemon) hostedFailWaitingLocked(h *hostedServer, answer json.RawMessage) {
	for id, c := range h.waiting {
		c <- answer
		delete(h.waiting, id)
	}
}

// hostedStoppedLocked is stoppedWhileInUse: it stopped, or never started, while something
// used it. Started again after a wait that doubles with each quick failure.
func (d *Daemon) hostedStoppedLocked(h *hostedServer, why string) {
	h.cmd, h.in, h.initialized = nil, nil, nil
	h.lastError = why
	if h.lastStderr != "" {
		h.lastError = why + " " + h.lastStderr
	}
	h.lastStderr = ""
	ran := time.Duration(0)
	if h.since != nil {
		ran = nowFunc().Sub(*h.since)
	}
	if ran >= hostedSteadyAfter {
		h.failures = 1
	} else {
		h.failures++
	}
	h.since = nil
	if len(h.users) == 0 || d.hostedStopped {
		h.state = wire.HostedMCPStateIdle
		d.hostedChangedLocked()
		return
	}
	wait := min(hostedBackoffMax, time.Duration(math.Pow(2, float64(h.failures-1)))*time.Second)
	at := nowFunc().Add(wait)
	h.state, h.retryAt = wire.HostedMCPStateRestarting, &at
	if h.retry != nil {
		h.retry.Stop()
	}
	h.retry = time.AfterFunc(wait, func() { d.hostedRestart(h) })
	d.hostedChangedLocked()
}

func (d *Daemon) hostedRestart(h *hostedServer) {
	d.hostedMu.Lock()
	if h.state != wire.HostedMCPStateRestarting || len(h.users) == 0 || d.hostedStopped {
		d.hostedMu.Unlock()
		return
	}
	h.state, h.retryAt = wire.HostedMCPStateIdle, nil
	h.restarts++
	d.hostedMu.Unlock()
	d.hostedReady(h)
}

// hostedIdleLocked lets the process go: nothing uses it.
func (d *Daemon) hostedIdleLocked(h *hostedServer) {
	if h.retry != nil {
		h.retry.Stop()
		h.retry = nil
	}
	h.retryAt, h.since, h.initialized = nil, nil, nil
	h.state = wire.HostedMCPStateIdle
	h.sessions = map[string]bool{}
	if h.cmd == nil {
		return
	}
	cmd, in := h.cmd, h.in
	h.cmd, h.in = nil, nil
	h.generation++
	d.hostedFailWaitingLocked(h, hostedAnswer(-32000, h.key.name+" is no longer in use."))
	hostedEnd(cmd, in)
	log.Printf("hosted mcp: %s idle", h.key.name)
}

// hostedEnd asks a server to go, and its process group goes two seconds later. The reader
// waits for it.
func hostedEnd(cmd *exec.Cmd, in io.WriteCloser) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	if in != nil {
		in.Close()
	}
	pid := cmd.Process.Pid
	syscall.Kill(-pid, syscall.SIGTERM)
	time.AfterFunc(hostedKillAfter, func() { syscall.Kill(-pid, syscall.SIGKILL) })
}

// MARK: stderr

// hostedLogName is logName: the same file for the same server in the same place.
func hostedLogName(k hostedKey) string {
	safeName := strings.Map(func(r rune) rune {
		if r == '-' || r == '_' || ('a' <= r && r <= 'z') || ('A' <= r && r <= 'Z') || ('0' <= r && r <= '9') {
			return r
		}
		return '_'
	}, k.name)
	f := fnv.New64a()
	f.Write([]byte(k.scope))
	sum := strconv.FormatUint(f.Sum64(), 16)
	if len(sum) > 8 {
		sum = sum[:8]
	}
	return safeName + "-" + sum + ".log"
}

func (d *Daemon) hostedLogLocked(h *hostedServer) *hostedLog {
	if h.log == nil && d.Store != nil && d.Store.Loc.Logs != "" {
		h.log = &hostedLog{path: filepath.Join(d.Store.Loc.Logs, "mcp-logs", hostedLogName(h.key))}
		dropOldHostedLogs(filepath.Dir(h.log.path), filepath.Base(h.log.path))
	}
	return h.log
}

// hostedLogsKept is how many servers' logs mcp-logs keeps, each with its rolled .1 (#2292).
const hostedLogsKept = 32

// dropOldHostedLogs deletes all but the newest hostedLogsKept logs in mcp-logs, never
// keep's (#2292): a server that is gone, or moved to another scope, leaves its log.
func dropOldHostedLogs(dir, keep string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	type logFile struct {
		name string
		at   time.Time
	}
	var logs []logFile
	for _, e := range entries {
		if name := e.Name(); strings.HasSuffix(name, ".log") && name != keep {
			if fi, err := e.Info(); err == nil {
				logs = append(logs, logFile{name, fi.ModTime()})
			}
		}
	}
	if len(logs) < hostedLogsKept {
		return
	}
	sort.Slice(logs, func(i, j int) bool { return logs[i].at.After(logs[j].at) })
	// One place is keep's.
	for _, l := range logs[hostedLogsKept-1:] {
		os.Remove(filepath.Join(dir, l.name))
		os.Remove(filepath.Join(dir, l.name+".1"))
	}
}

// hostedLog is a file of a server's own, started again past hostedLogLimit.
type hostedLog struct {
	mu   sync.Mutex
	path string
}

func (l *hostedLog) write(p []byte) {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	os.MkdirAll(filepath.Dir(l.path), 0o700)
	if fi, err := os.Stat(l.path); err == nil && fi.Size()+int64(len(p)) > hostedLogLimit {
		os.Rename(l.path, l.path+".1")
	}
	f, err := os.OpenFile(l.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	f.Write(p)
	f.Close()
}

type hostedStderr struct {
	d   *Daemon
	h   *hostedServer
	log *hostedLog
}

func (s *hostedStderr) Write(p []byte) (int, error) {
	s.log.write(p)
	lines := strings.Split(string(p), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if t := strings.TrimSpace(lines[i]); t != "" {
			if len(t) > 300 {
				t = t[:300]
			}
			s.d.hostedMu.Lock()
			s.h.lastStderr = t
			s.d.hostedMu.Unlock()
			break
		}
	}
	return len(p), nil
}
