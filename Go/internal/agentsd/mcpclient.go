package agentsd

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"

	sdk "github.com/coder/acp-go-sdk"
)

// A check of an MCP server as a session would reach it (MCPClient, #753): started or
// connected, initialize, notifications/initialized, tools/list to its end, then ended.
// stdio is a line of JSON each way; http is MCP's streamable HTTP, an answer as JSON or
// as server-sent events, with the session id the server gives. sse is not spoken.

// mcpCheckFailure is MCPClient.Failure, said as MCPHandEntry.sentence says it.
type mcpCheckFailure struct {
	kind    string // authRequired, httpStatus, sessionExpired, unreachable, stopped, timedOut, refused, notMCP
	status  int
	message string
	// code and data are a refusal's JSON-RPC error, as the server gave them.
	code int
	data json.RawMessage
}

func (f *mcpCheckFailure) Error() string { return f.kind }

func (f *mcpCheckFailure) sentence(timeout time.Duration) string {
	switch f.kind {
	case "authRequired":
		return "It asks for a sign-in."
	case "httpStatus":
		return fmt.Sprintf("It answered with HTTP %d, not as an MCP server.", f.status)
	case "sessionExpired":
		return "It dropped the session it had just opened."
	case "unreachable":
		return f.message
	case "stopped":
		if f.message == "" || f.message == "The server stopped." {
			return "The server stopped before it answered."
		}
		return f.message
	case "timedOut":
		return fmt.Sprintf("It did not answer within %d seconds.", int(timeout.Seconds()))
	case "refused":
		if f.message == "" {
			return "It refused to start a session."
		}
		return "It refused: " + f.message
	}
	return "What came back was not MCP."
}

type mcpReply struct {
	ID     json.RawMessage `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Code    int             `json:"code"`
		Message string          `json:"message"`
		Data    json.RawMessage `json:"data"`
	} `json:"error"`
	Method string `json:"method"`
}

// mcpConn is one way to a server: a request and its answer, or a notification.
type mcpConn interface {
	call(ctx context.Context, id int, method string, params any) (json.RawMessage, error)
	notify(ctx context.Context, method string) error
	end()
}

// checkMCP connects, lists the tools and ends: how many it has, or why it did not answer.
func checkMCP(ctx context.Context, s sdk.McpServer, cwd string, timeout time.Duration) (int, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var c mcpConn
	switch {
	case s.Stdio != nil:
		sc, err := startStdioMCP(s.Stdio, cwd)
		if err != nil {
			return 0, err
		}
		c = sc
	case s.Http != nil:
		c = &httpMCP{url: s.Http.Url, headers: s.Http.Headers}
	default:
		return 0, &mcpCheckFailure{kind: "notMCP"}
	}
	defer c.end()
	timedOut := func(err error) error {
		if ctx.Err() != nil {
			return &mcpCheckFailure{kind: "timedOut"}
		}
		return err
	}
	if _, err := c.call(ctx, 1, "initialize", map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{},
		"clientInfo": map[string]any{"name": "Agents", "version": "1"}}); err != nil {
		return 0, timedOut(err)
	}
	if err := c.notify(ctx, "notifications/initialized"); err != nil {
		return 0, timedOut(err)
	}
	tools, cursor := 0, ""
	for id := 2; ; id++ {
		params := map[string]any{}
		if cursor != "" {
			params["cursor"] = cursor
		}
		raw, err := c.call(ctx, id, "tools/list", params)
		if err != nil {
			return 0, timedOut(err)
		}
		var page struct {
			Tools      []json.RawMessage `json:"tools"`
			NextCursor string            `json:"nextCursor"`
		}
		if json.Unmarshal(raw, &page) != nil {
			return 0, &mcpCheckFailure{kind: "notMCP"}
		}
		tools += len(page.Tools)
		if page.NextCursor == "" || id > 50 {
			return tools, nil
		}
		cursor = page.NextCursor
	}
}

func answerOf(raw []byte, id int) (json.RawMessage, bool, error) {
	return answerHeard(raw, id, nil)
}

// answerHeard is answerOf, telling heard the method of a notification that is not the answer.
func answerHeard(raw []byte, id int, heard func(string)) (json.RawMessage, bool, error) {
	var r mcpReply
	if json.Unmarshal(raw, &r) != nil {
		return nil, false, nil
	}
	// A message with a method is the server's own: a notification, or a request of its own
	// whose id may be the same number as ours.
	if r.Method != "" {
		if heard != nil && len(r.ID) == 0 {
			heard(r.Method)
		}
		return nil, false, nil
	}
	if string(r.ID) != fmt.Sprint(id) {
		return nil, false, nil
	}
	if r.Error != nil {
		return nil, true, &mcpCheckFailure{kind: "refused", message: r.Error.Message, code: r.Error.Code, data: r.Error.Data}
	}
	if r.Result == nil {
		return nil, true, &mcpCheckFailure{kind: "notMCP"}
	}
	return r.Result, true, nil
}

func request(id int, method string, params any) []byte {
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params})
	return b
}

// stdioMCP is a server the check starts, ended when the check is.
type stdioMCP struct {
	cmd   *exec.Cmd
	in    io.WriteCloser
	lines chan []byte
	// gone is closed as the check ends, so the reader never waits on a line nobody takes.
	gone chan struct{}
	// heard is told each notification's method, seen while a call waits for its answer.
	heard func(string)
}

func startStdioMCP(s *sdk.McpServerStdio, cwd string) (*stdioMCP, error) {
	cmd := exec.Command(s.Command, s.Args...)
	cmd.Dir = cwd
	cmd.Env = os.Environ()
	for _, e := range s.Env {
		cmd.Env = append(cmd.Env, e.Name+"="+e.Value)
	}
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, &mcpCheckFailure{kind: "stopped", message: "It could not be started."}
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, &mcpCheckFailure{kind: "stopped", message: "It could not be started."}
	}
	if err := cmd.Start(); err != nil {
		return nil, &mcpCheckFailure{kind: "stopped", message: "It could not be started: " + strings.TrimPrefix(err.Error(), "exec: ") + "."}
	}
	c := &stdioMCP{cmd: cmd, in: in, lines: make(chan []byte, 16), gone: make(chan struct{})}
	go func() {
		r := bufio.NewReaderSize(out, 64*1024)
		defer close(c.lines)
		for {
			line, err := r.ReadBytes('\n')
			if len(bytes.TrimSpace(line)) > 0 {
				select {
				case c.lines <- line:
				case <-c.gone:
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()
	return c, nil
}

func (c *stdioMCP) call(ctx context.Context, id int, method string, params any) (json.RawMessage, error) {
	if _, err := c.in.Write(append(request(id, method, params), '\n')); err != nil {
		return nil, &mcpCheckFailure{kind: "stopped", message: "The server stopped."}
	}
	for {
		select {
		case <-ctx.Done():
			return nil, &mcpCheckFailure{kind: "timedOut"}
		case line, ok := <-c.lines:
			if !ok {
				return nil, &mcpCheckFailure{kind: "stopped", message: "The server stopped."}
			}
			if r, done, err := answerHeard(line, id, c.heard); done {
				return r, err
			}
		}
	}
}

func (c *stdioMCP) notify(_ context.Context, method string) error {
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "method": method})
	if _, err := c.in.Write(append(b, '\n')); err != nil {
		return &mcpCheckFailure{kind: "stopped", message: "The server stopped."}
	}
	return nil
}

// end closes its input, the way to ask a stdio server to go, then ends it.
func (c *stdioMCP) end() {
	close(c.gone)
	c.in.Close()
	done := make(chan struct{})
	go func() { c.cmd.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		c.cmd.Process.Kill()
		<-done
	}
}

// httpMCP is a streamable HTTP server.
type httpMCP struct {
	url     string
	headers []sdk.HttpHeader
	session string
	heard   func(string)
}

func (c *httpMCP) post(ctx context.Context, body []byte) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.url, bytes.NewReader(body))
	if err != nil {
		return nil, &mcpCheckFailure{kind: "unreachable", message: "That is not an address."}
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	for _, h := range c.headers {
		req.Header.Set(h.Name, h.Value)
	}
	if c.session != "" {
		req.Header.Set("Mcp-Session-Id", c.session)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, &mcpCheckFailure{kind: "timedOut"}
		}
		return nil, &mcpCheckFailure{kind: "unreachable", message: "It could not be reached."}
	}
	switch {
	case res.StatusCode == http.StatusUnauthorized:
		res.Body.Close()
		return nil, &mcpCheckFailure{kind: "authRequired"}
	case res.StatusCode == http.StatusNotFound && c.session != "":
		res.Body.Close()
		return nil, &mcpCheckFailure{kind: "sessionExpired"}
	case res.StatusCode >= 300:
		res.Body.Close()
		return nil, &mcpCheckFailure{kind: "httpStatus", status: res.StatusCode}
	}
	if s := res.Header.Get("Mcp-Session-Id"); s != "" {
		c.session = s
	}
	return res, nil
}

func (c *httpMCP) call(ctx context.Context, id int, method string, params any) (json.RawMessage, error) {
	res, err := c.post(ctx, request(id, method, params))
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	kind, _, _ := mime.ParseMediaType(res.Header.Get("Content-Type"))
	if kind != "text/event-stream" {
		body, err := io.ReadAll(io.LimitReader(res.Body, 8<<20))
		if err != nil {
			return nil, &mcpCheckFailure{kind: "unreachable", message: "It could not be reached."}
		}
		if r, done, err := answerOf(body, id); done {
			return r, err
		}
		return nil, &mcpCheckFailure{kind: "notMCP"}
	}
	// Events until the one that answers: each event's data lines, joined.
	r := bufio.NewReaderSize(res.Body, 64*1024)
	var data []string
	for {
		line, err := r.ReadString('\n')
		line = strings.TrimRight(line, "\r\n")
		switch {
		case strings.HasPrefix(line, "data:"):
			data = append(data, strings.TrimPrefix(strings.TrimPrefix(line, "data:"), " "))
		case line == "" && len(data) > 0:
			if a, done, aerr := answerHeard([]byte(strings.Join(data, "\n")), id, c.heard); done {
				return a, aerr
			}
			data = nil
		}
		if err != nil {
			if ctx.Err() != nil {
				return nil, &mcpCheckFailure{kind: "timedOut"}
			}
			return nil, &mcpCheckFailure{kind: "notMCP"}
		}
	}
}

func (c *httpMCP) notify(ctx context.Context, method string) error {
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "method": method})
	res, err := c.post(ctx, b)
	if err != nil {
		return err
	}
	res.Body.Close()
	return nil
}

// end lets the server forget the session, where it gave one.
func (c *httpMCP) end() {
	if c.session == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, c.url, nil)
	if err != nil {
		return
	}
	for _, h := range c.headers {
		req.Header.Set(h.Name, h.Value)
	}
	req.Header.Set("Mcp-Session-Id", c.session)
	if res, err := http.DefaultClient.Do(req); err == nil {
		res.Body.Close()
	}
}

// mcpFailureOf is the failure an error is, or "It could not be reached."
func mcpFailureOf(err error) *mcpCheckFailure {
	var f *mcpCheckFailure
	if errors.As(err, &f) {
		return f
	}
	return &mcpCheckFailure{kind: "unreachable", message: "It could not be reached."}
}
