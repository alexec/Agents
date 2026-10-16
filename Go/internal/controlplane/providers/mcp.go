package providers

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
)

// The app's MCP client for providers: MCPToolClient, MCPClient and MCPStdioProcess, cut
// down to what a provider needs. A connection, its tools, and calls to them, over stdio
// or streamable http. Logged: the server's name and what happened in a word, never its
// command, environment, headers, URL or any body.

const mcpProtocolVersion = "2025-06-18"

// mcpServer is MCPServer: a stdio server the control plane runs, or one at an address.
type mcpServer struct {
	Name string
	// stdio
	Command string
	Args    []string
	Env     map[string]string
	// streamable http, when HTTP is set
	HTTP    bool
	URL     string
	Headers map[string]string
}

func (s mcpServer) isHTTP() bool { return s.HTTP }

// mcpFailure is MCPClient.Failure, worded as MCPToolClient.failure words it.
type mcpFailure struct {
	kind   string // auth, status, expired, unreachable, stopped, timeout, refused, notMCP
	words  string
	status int
	code   int
}

func (f *mcpFailure) Error() string {
	switch f.kind {
	case "auth":
		return "It wants a sign-in first."
	case "status":
		return fmt.Sprintf("It answered with HTTP %d.", f.status)
	case "expired":
		return "It forgot this session."
	case "stopped":
		if f.words == "" {
			return "The server stopped."
		}
		return f.words
	case "timeout":
		return "It didn’t answer in time."
	case "notMCP":
		return "What it answered isn’t MCP."
	}
	return f.words
}

// logWord is one word for the log: never the server's own text.
func (f *mcpFailure) logWord() string {
	switch f.kind {
	case "auth":
		return "auth required"
	case "status":
		return fmt.Sprintf("http %d", f.status)
	case "expired":
		return "session expired"
	case "timeout":
		return "timed out"
	case "refused":
		return fmt.Sprintf("refused %d", f.code)
	case "notMCP":
		return "not MCP"
	}
	return f.kind
}

// retriable: the connection went, so a new one may do what this one could not. Never
// after the server heard the call and said no, or ran out of time.
func (f *mcpFailure) retriable() bool {
	return f.kind == "stopped" || f.kind == "expired" || f.kind == "unreachable"
}

// mcpClient is MCPToolClient over MCPClient.
type mcpClient struct {
	server  mcpServer
	cwd     string
	timeout time.Duration
	log     func(string)

	mu         sync.Mutex
	nextID     int
	stdio      *stdioProcess
	sessionID  string
	negotiated string
	http       *http.Client
}

func newMCPClient(server mcpServer, cwd string, timeout time.Duration, log func(string)) *mcpClient {
	return &mcpClient{server: server, cwd: cwd, timeout: timeout, log: log, nextID: 1, http: &http.Client{}}
}

// connect starts the server or opens the session, and initializes.
func (c *mcpClient) connect() error {
	err := func() error {
		if !c.server.isHTTP() {
			p := startStdio(c.server, c.cwd, c.log)
			c.mu.Lock()
			c.stdio = p
			c.mu.Unlock()
			if why, stopped := p.stoppedBecause(); stopped {
				return &mcpFailure{kind: "stopped", words: why}
			}
		}
		params := map[string]any{
			"protocolVersion": mcpProtocolVersion,
			"capabilities": map[string]any{"extensions": map[string]any{
				"io.modelcontextprotocol/ui": map[string]any{"mimeTypes": []string{"text/html;profile=mcp-app"}}}},
			"clientInfo": map[string]any{"name": "Agents", "version": "1"},
		}
		result, err := c.request("initialize", params, false, 0)
		if err != nil {
			return err
		}
		if result == nil {
			return &mcpFailure{kind: "notMCP"}
		}
		negotiated, _ := str(get(result, "protocolVersion"))
		c.mu.Lock()
		c.negotiated = negotiated
		c.mu.Unlock()
		return c.notify("notifications/initialized")
	}()
	var f *mcpFailure
	if errors.As(err, &f) {
		c.log("mcp client: " + c.server.Name + " did not answer (" + f.logWord() + ")")
		return f
	}
	if err != nil {
		return err
	}
	c.log("mcp client: " + c.server.Name + " answered")
	return nil
}

// end stops the stdio server, or closes the http session. Safe to call more than once.
func (c *mcpClient) end() {
	c.mu.Lock()
	p, session := c.stdio, c.sessionID
	c.stdio, c.sessionID = nil, ""
	c.mu.Unlock()
	if p != nil {
		p.end("The app's client has ended.")
	}
	if c.server.isHTTP() && session != "" {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if req, err := http.NewRequestWithContext(ctx, http.MethodDelete, c.server.URL, nil); err == nil {
			for name, value := range c.server.Headers {
				req.Header.Set(name, value)
			}
			req.Header.Set("Mcp-Session-Id", session)
			if resp, err := c.http.Do(req); err == nil {
				resp.Body.Close()
			}
		}
	}
	c.log("mcp client: " + c.server.Name + " ended")
}

// listTools is every tool, as the server described it, through nextCursor: at most 10
// pages and 500 tools.
func (c *mcpClient) listTools() ([]any, error) {
	var items []any
	var cursor string
	for range 10 {
		params := map[string]any{}
		if cursor != "" {
			params["cursor"] = cursor
		}
		result, err := c.request("tools/list", params, true, 0)
		if err != nil {
			return nil, err
		}
		if result == nil {
			break
		}
		page, _ := arr(get(result, "tools"))
		items = append(items, page...)
		cursor, _ = str(get(result, "nextCursor"))
		if cursor == "" || len(items) >= 500 {
			break
		}
	}
	if len(items) > 500 {
		items = items[:500]
	}
	var out []any
	for _, raw := range items {
		if _, ok := str(get(raw, "name")); ok {
			out = append(out, raw)
		}
	}
	return out, nil
}

// toolNames is every tool's name.
func (c *mcpClient) toolNames() ([]string, error) {
	tools, err := c.listTools()
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(tools))
	for _, t := range tools {
		names = append(names, strOr(get(t, "name")))
	}
	return names, nil
}

// callTool is tools/call's whole result; timeout overrides the client's own.
func (c *mcpClient) callTool(name string, arguments any, timeout time.Duration) (any, error) {
	result, err := c.request("tools/call", map[string]any{"name": name, "arguments": arguments}, false, timeout)
	if err != nil {
		return nil, err
	}
	if result == nil {
		return nil, &mcpFailure{kind: "notMCP"}
	}
	return result, nil
}

// request is the result of method: nil only when optional and the server has no such method.
func (c *mcpClient) request(method string, params any, optional bool, timeout time.Duration) (any, error) {
	if timeout <= 0 {
		timeout = c.timeout
	}
	c.mu.Lock()
	id := c.nextID
	c.nextID++
	c.mu.Unlock()
	body, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params})
	if err != nil {
		return nil, err
	}
	reply, err := c.exchange(body, id, timeout)
	if err != nil {
		return nil, err
	}
	message, err := parseJSON(reply)
	if err != nil {
		return nil, &mcpFailure{kind: "notMCP"}
	}
	if got, ok := integer(get(message, "id")); !ok || got != id {
		return nil, &mcpFailure{kind: "notMCP"}
	}
	if e := get(message, "error"); e != nil {
		code, _ := integer(get(e, "code"))
		if optional && code == CodeMethodNotFound {
			return nil, nil
		}
		c.mu.Lock()
		p := c.stdio
		c.mu.Unlock()
		if code == -32000 && p != nil {
			if why, stopped := p.stoppedBecause(); stopped {
				return nil, &mcpFailure{kind: "stopped", words: why}
			}
		}
		return nil, &mcpFailure{kind: "refused", words: strOr(get(e, "message")), code: code}
	}
	if !has(message, "result") {
		return nil, &mcpFailure{kind: "notMCP"}
	}
	return get(message, "result"), nil
}

func (c *mcpClient) notify(method string) error {
	body, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "method": method})
	if c.server.isHTTP() {
		_, err := c.post(body, 0, false, c.timeout)
		return err
	}
	c.mu.Lock()
	p := c.stdio
	c.mu.Unlock()
	if p != nil {
		p.write(body)
	}
	return nil
}

// exchange is one request out and its answer back, within timeout.
func (c *mcpClient) exchange(body []byte, id int, timeout time.Duration) ([]byte, error) {
	if c.server.isHTTP() {
		reply, err := c.post(body, id, true, timeout)
		if err != nil {
			return nil, err
		}
		if reply == nil {
			return nil, &mcpFailure{kind: "notMCP"}
		}
		return reply, nil
	}
	c.mu.Lock()
	p := c.stdio
	c.mu.Unlock()
	if p == nil {
		return nil, &mcpFailure{kind: "stopped", words: "The server is not running."}
	}
	return p.send(body, id, timeout)
}

// post sends one message over streamable http: the answer to id, or nil for a
// notification.
func (c *mcpClient) post(body []byte, id int, wantsAnswer bool, timeout time.Duration) ([]byte, error) {
	address, err := url.Parse(c.server.URL)
	if err != nil || (strings.ToLower(address.Scheme) != "http" && strings.ToLower(address.Scheme) != "https") {
		return nil, &mcpFailure{kind: "unreachable", words: "That is not an http or https address."}
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.server.URL, bytes.NewReader(body))
	if err != nil {
		return nil, &mcpFailure{kind: "unreachable", words: "It could not be reached."}
	}
	for name, value := range c.server.Headers {
		req.Header.Set(name, value)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	c.mu.Lock()
	session, negotiated := c.sessionID, c.negotiated
	c.mu.Unlock()
	if session != "" {
		req.Header.Set("Mcp-Session-Id", session)
	}
	if negotiated != "" {
		req.Header.Set("MCP-Protocol-Version", negotiated)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, &mcpFailure{kind: "timeout"}
		}
		return nil, &mcpFailure{kind: "unreachable", words: reachWords(err)}
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		if ctx.Err() != nil {
			return nil, &mcpFailure{kind: "timeout"}
		}
		return nil, &mcpFailure{kind: "unreachable", words: reachWords(err)}
	}
	switch {
	case resp.StatusCode == 401:
		return nil, &mcpFailure{kind: "auth"}
	case resp.StatusCode == 404 && session != "":
		c.mu.Lock()
		c.sessionID = ""
		c.mu.Unlock()
		return nil, &mcpFailure{kind: "expired"}
	case resp.StatusCode < 200 || resp.StatusCode >= 300:
		return nil, &mcpFailure{kind: "status", status: resp.StatusCode}
	}
	if given := resp.Header.Get("Mcp-Session-Id"); given != "" {
		c.mu.Lock()
		c.sessionID = given
		c.mu.Unlock()
	}
	if !wantsAnswer {
		return nil, nil
	}
	if strings.HasPrefix(strings.ToLower(resp.Header.Get("Content-Type")), "text/event-stream") {
		answer := answerInEvents(id, data)
		if answer == nil {
			return nil, &mcpFailure{kind: "notMCP"}
		}
		return answer, nil
	}
	return data, nil
}

// answerInEvents is MCPClient.answer(_:inEvents:): the JSON-RPC answer to id among an
// event stream's data: events.
func answerInEvents(id int, data []byte) []byte {
	text := strings.ReplaceAll(string(data), "\r\n", "\n")
	for _, event := range strings.Split(text, "\n\n") {
		var lines []string
		for _, line := range strings.Split(event, "\n") {
			if rest, ok := strings.CutPrefix(line, "data:"); ok {
				lines = append(lines, strings.TrimPrefix(rest, " "))
			}
		}
		if len(lines) == 0 {
			continue
		}
		payload := []byte(strings.Join(lines, "\n"))
		message, err := parseJSON(payload)
		if err != nil {
			continue
		}
		if got, ok := integer(get(message, "id")); ok && got == id && (has(message, "result") || has(message, "error")) {
			return payload
		}
	}
	return nil
}

// reachWords is MCPClient.reason: what went wrong reaching it, without the address.
func reachWords(err error) string {
	var dns *net.DNSError
	var certificate *x509.UnknownAuthorityError
	var hostname x509.HostnameError
	var invalid x509.CertificateInvalidError
	var record tls.RecordHeaderError
	var timeout interface{ Timeout() bool }
	switch {
	case errors.As(err, &dns):
		return "Its host could not be found."
	case errors.Is(err, syscall.ECONNREFUSED):
		return "Nothing answered at that address."
	case errors.As(err, &certificate), errors.As(err, &hostname), errors.As(err, &invalid), errors.As(err, &record):
		return "Its secure connection could not be made."
	case errors.As(err, &timeout) && timeout.Timeout():
		return "It did not answer in time."
	}
	return "It could not be reached."
}

// mcpEnvironment is RuntimeEnvironment.forMCPServers in the control plane: only what any
// program needs of its own environment, never all of it (#727).
func mcpEnvironment() map[string]string {
	allowed := []string{
		"PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "TZ",
		"LANG", "LANGUAGE", "LC_*", "TERM", "COLORTERM", "XDG_*", "__CF_USER_TEXT_ENCODING",
		"EDITOR", "VISUAL", "PAGER", "SSH_AUTH_SOCK",
		"HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "no_proxy", "all_proxy",
		"SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE",
		"DEVELOPER_DIR", "JAVA_HOME", "GOPATH", "GOROOT", "CARGO_HOME", "RUSTUP_HOME", "PYENV_ROOT", "NVM_DIR",
		"AGENTS_*",
	}
	out := map[string]string{}
	for _, kv := range os.Environ() {
		name, value, _ := strings.Cut(kv, "=")
		for _, pattern := range allowed {
			if prefix, ok := strings.CutSuffix(pattern, "*"); ok && strings.HasPrefix(name, prefix) || name == pattern {
				out[name] = value
				break
			}
		}
	}
	return out
}

// stdioProcess is MCPStdioProcess: a stdio MCP server, and the requests waiting for their
// answers, matched by id.
type stdioProcess struct {
	name string
	log  func(string)
	cmd  *exec.Cmd
	in   io.WriteCloser

	mu        sync.Mutex
	writeMu   sync.Mutex
	waiting   map[int]chan []byte
	ended     bool
	endReason string
	exited    chan struct{}
}

func startStdio(server mcpServer, cwd string, log func(string)) *stdioProcess {
	p := &stdioProcess{name: server.Name, log: log, waiting: map[int]chan []byte{}, endReason: "The server stopped.",
		exited: make(chan struct{})}
	cmd := exec.Command("/usr/bin/env", append([]string{server.Command}, server.Args...)...)
	env := mcpEnvironment()
	for k, v := range server.Env {
		env[k] = v
	}
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	if info, err := os.Stat(cwd); err == nil && info.IsDir() {
		cmd.Dir = cwd
	}
	in, err1 := cmd.StdinPipe()
	out, err2 := cmd.StdoutPipe()
	if err1 != nil || err2 != nil || cmd.Start() != nil {
		log("mcp client: " + server.Name + " could not start")
		p.ended, p.endReason = true, "The server could not be started."
		close(p.exited)
		return p
	}
	p.cmd, p.in = cmd, in
	log(fmt.Sprintf("mcp client: %s started (pid %d)", server.Name, cmd.Process.Pid))
	go p.read(out)
	return p
}

func (p *stdioProcess) stoppedBecause() (string, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.endReason, p.ended
}

func (p *stdioProcess) read(out io.Reader) {
	r := bufio.NewReaderSize(out, 64*1024)
	for {
		line, err := r.ReadBytes('\n')
		if len(bytes.TrimSpace(line)) > 0 {
			p.handle(bytes.TrimSpace(line))
		}
		if err != nil {
			break
		}
	}
	err := p.cmd.Wait()
	reason := "The server stopped."
	var exit *exec.ExitError
	// env says 127 when it found no such command.
	if errors.As(err, &exit) && exit.ExitCode() == 127 {
		reason = "The command was not found."
	}
	close(p.exited)
	p.end(reason)
}

func (p *stdioProcess) handle(line []byte) {
	message, err := parseJSON(line)
	if err != nil {
		return
	}
	if has(message, "method") {
		// The server speaking first: a request is told no, so it does not wait forever; a
		// notification is dropped.
		if has(message, "id") {
			reply, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": get(message, "id"),
				"error": map[string]any{"code": CodeMethodNotFound, "message": "Not passed on by the app."}})
			p.write(reply)
		}
		return
	}
	id, ok := integer(get(message, "id"))
	if !ok {
		return
	}
	p.mu.Lock()
	done := p.waiting[id]
	delete(p.waiting, id)
	p.mu.Unlock()
	if done != nil {
		done <- line
	}
}

func (p *stdioProcess) write(body []byte) {
	if p.in == nil {
		return
	}
	line := append(bytes.TrimRight(body, "\n"), '\n')
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	p.in.Write(line)
}

// send writes one request and waits for the answer with the same id, or until timeout.
func (p *stdioProcess) send(body []byte, id int, timeout time.Duration) ([]byte, error) {
	done := make(chan []byte, 1)
	p.mu.Lock()
	if p.ended {
		reason := p.endReason
		p.mu.Unlock()
		return stdioError(id, reason), nil
	}
	p.waiting[id] = done
	p.mu.Unlock()
	p.write(body)
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case reply := <-done:
		return reply, nil
	case <-timer.C:
		// Abandoned: an answer that comes later is dropped.
		p.mu.Lock()
		delete(p.waiting, id)
		p.mu.Unlock()
		return nil, &mcpFailure{kind: "timeout"}
	}
}

func stdioError(id int, reason string) []byte {
	data, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id,
		"error": map[string]any{"code": -32000, "message": reason}})
	return data
}

// end stops it: every waiting request is answered with why, and the process is told to
// end, then killed 2 seconds later.
func (p *stdioProcess) end(reason string) {
	p.mu.Lock()
	if !p.ended {
		p.endReason = reason
	}
	p.ended = true
	pending := p.waiting
	p.waiting = map[int]chan []byte{}
	reason = p.endReason
	p.mu.Unlock()
	for id, done := range pending {
		done <- stdioError(id, reason)
	}
	if p.cmd == nil || p.cmd.Process == nil {
		return
	}
	select {
	case <-p.exited:
		return
	default:
	}
	if p.in != nil {
		p.in.Close()
	}
	p.cmd.Process.Signal(syscall.SIGTERM)
	go func() {
		select {
		case <-p.exited:
		case <-time.After(2 * time.Second):
			p.cmd.Process.Kill()
		}
	}()
}
