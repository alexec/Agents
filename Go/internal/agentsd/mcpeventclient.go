package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/Go/wire"
)

// The host's connections for servers' events (#383, MCPEventClients and MCPEventsWire): the
// little of the MCP events draft (`experimental-ext-triggers-events`) the Swift host
// speaks, poll mode only. One connection per server, shared by its subscriptions; at most
// mcpEventConnLimit, the next refused rather than ending one in use; stdio allowed, the
// host running its own copy of the server with the environment and secrets a session
// would give it; each call within mcpEventTimeout. Who may be connected to is decided
// before this is asked. Logged: the server's name and a word.

const (
	mcpEventConnLimit = 8
	mcpEventTimeout   = 15 * time.Second
	// mcpEventProtocol is the newest version an event connection offers; any is taken back.
	mcpEventProtocol    = "2026-07-28"
	mcpEventsListMethod = "events/list"
	mcpEventsPollMethod = "events/poll"
	mcpEventsChanged    = "notifications/events/list_changed"
	// mcpEventListLimit is the most events/list pages, and events, kept.
	mcpEventListPages = 50
	mcpEventListLimit = 1000
)

var mcpTooMany = fmt.Sprintf("Too many servers with events on this machine (%d).", mcpEventConnLimit)

// mcpEventDef is EventDefinition: one entry of events/list.
type mcpEventDef struct {
	Name          string          `json:"name"`
	Description   *string         `json:"description,omitempty"`
	Delivery      []string        `json:"delivery"`
	InputSchema   json.RawMessage `json:"inputSchema,omitempty"`
	PayloadSchema json.RawMessage `json:"payloadSchema,omitempty"`
}

func (e mcpEventDef) offersPoll() bool { return contains(e.Delivery, "poll") }

// wireText is the definition as canonical JSON: part of what a stopped subscription waits
// to see change.
func (e mcpEventDef) wireText() string {
	if e.Delivery == nil {
		e.Delivery = []string{}
	}
	return canonicalJSON(mustRaw(e))
}

// mcpPolled is one event from events/poll.
type mcpPolled struct {
	EventID   *string         `json:"eventId"`
	Name      *string         `json:"name"`
	Timestamp *string         `json:"timestamp"`
	Data      json.RawMessage `json:"data"`
	// Sender is who sent a channel message (#1762): such an event starts work only as the
	// person the identity is linked to.
	Sender *wire.ChannelSender `json:"sender"`
}

// mcpPollResult is events/poll's answer; a nil cursor keeps the one before.
type mcpPollResult struct {
	Events     []mcpPolled `json:"events"`
	Cursor     *string     `json:"cursor"`
	Truncated  bool        `json:"truncated"`
	HasMore    bool        `json:"hasMore"`
	NextPollMs *int        `json:"nextPollMs"`
}

// mcpEventsError is MCPEventsError: what went wrong asking a server for events, as the
// draft's codes and the transport say it.
type mcpEventsError struct {
	// kind is notFound, forbidden, exhausted, unsupported, invalidParams, serverError,
	// needsSignIn, transport or timedOut.
	kind         string
	message      string
	reason       string
	retryAfterMs int
}

func (e *mcpEventsError) Error() string { return e.kind }

func mcpEventsErrorOf(err error) *mcpEventsError {
	var already *mcpEventsError
	if errors.As(err, &already) {
		return already
	}
	f := mcpFailureOf(err)
	switch f.kind {
	case "refused":
		e := &mcpEventsError{message: f.message}
		var data struct {
			RetryAfterMs *int   `json:"retryAfterMs"`
			Reason       string `json:"reason"`
		}
		json.Unmarshal(f.data, &data)
		switch f.code {
		case -32011:
			e.kind = "notFound"
		case -32012:
			e.kind = "forbidden"
			// A sign-in that ended, or failed for a moment, is tried again as an HTTP 401 is
			// (#2457): stopped, a wait on pr.merged never woke though the next poll would do.
			if data.Reason == "not connected" || strings.Contains(strings.ToLower(data.Reason), "not signed in") {
				e.kind = "needsSignIn"
			}
		case -32013:
			e.kind = "exhausted"
			if data.RetryAfterMs != nil {
				e.retryAfterMs = *data.RetryAfterMs
			}
		case -32014:
			e.kind, e.reason = "unsupported", data.Reason
		case -32602:
			e.kind = "invalidParams"
		default:
			e.kind = "serverError"
		}
		return e
	case "authRequired":
		return &mcpEventsError{kind: "needsSignIn"}
	case "httpStatus":
		switch {
		case f.status == 403:
			return &mcpEventsError{kind: "needsSignIn"}
		case f.status >= 500:
			return &mcpEventsError{kind: "transport", message: fmt.Sprintf("http %d", f.status)}
		}
		return &mcpEventsError{kind: "serverError", message: fmt.Sprintf("http %d", f.status)}
	case "timedOut":
		return &mcpEventsError{kind: "timedOut"}
	case "unreachable", "stopped":
		return &mcpEventsError{kind: "transport", message: f.message}
	case "sessionExpired":
		return &mcpEventsError{kind: "transport", message: "session expired"}
	}
	return &mcpEventsError{kind: "serverError", message: "What came back was not MCP."}
}

// logWord is one word for the log, never the server's own text.
func (e *mcpEventsError) logWord() string {
	switch e.kind {
	case "notFound":
		return "eventNotOffered"
	case "forbidden":
		return "refused"
	case "exhausted":
		return "rate limited"
	case "invalidParams":
		return "badArguments"
	case "transport":
		return "unreachable"
	case "timedOut":
		return "timed out"
	}
	return e.kind
}

// mcpEventConn is one server's connection, a call at a time.
type mcpEventConn struct {
	mu        sync.Mutex
	c         mcpConn
	next      int
	hasEvents bool
}

type mcpEventConns struct {
	mu   sync.Mutex
	held map[string]*mcpEventConn
	// heard is told which server said its events changed.
	heard   func(key string)
	timeout time.Duration
}

func newMCPEventConns(heard func(string)) *mcpEventConns {
	return &mcpEventConns{held: map[string]*mcpEventConn{}, heard: heard, timeout: mcpEventTimeout}
}

// with runs body with a connected client of the server, connecting first if none is. A
// session the server has forgotten is opened again, once.
func (p *mcpEventConns) with(key string, s sdk.McpServer, cwd string, body func(*mcpEventConn) error) error {
	p.mu.Lock()
	c := p.held[key]
	if c == nil {
		if len(p.held) >= mcpEventConnLimit {
			p.mu.Unlock()
			return &mcpEventsError{kind: "transport", message: mcpTooMany}
		}
		c = &mcpEventConn{}
		p.held[key] = c
	}
	p.mu.Unlock()
	c.mu.Lock()
	defer c.mu.Unlock()
	for attempt := 0; ; attempt++ {
		if c.c == nil {
			if err := p.connect(key, c, s, cwd); err != nil {
				p.forget(key, c)
				return err
			}
		}
		err := body(c)
		var f *mcpCheckFailure
		if attempt == 0 && errors.As(err, &f) && f.kind == "sessionExpired" {
			c.c.end()
			c.c = nil
			continue
		}
		return err
	}
}

func (p *mcpEventConns) connect(key string, c *mcpEventConn, s sdk.McpServer, cwd string) error {
	heard := func(method string) {
		if method == mcpEventsChanged && p.heard != nil {
			p.heard(key)
		}
	}
	switch {
	case s.Stdio != nil:
		sc, err := startStdioMCP(s.Stdio, cwd)
		if err != nil {
			return err
		}
		sc.heard = heard
		c.c = sc
	case s.Http != nil:
		c.c = &httpMCP{url: s.Http.Url, headers: s.Http.Headers, heard: heard}
	default:
		return &mcpEventsError{kind: "serverError", message: "It uses the old sse transport."}
	}
	raw, err := c.call(p.timeout, "initialize", map[string]any{"protocolVersion": mcpEventProtocol,
		"capabilities": map[string]any{}, "clientInfo": map[string]any{"name": "Agents", "version": "1"}})
	if err == nil {
		var init struct {
			Capabilities map[string]json.RawMessage `json:"capabilities"`
		}
		json.Unmarshal(raw, &init)
		_, c.hasEvents = init.Capabilities["events"]
		ctx, cancel := context.WithTimeout(context.Background(), p.timeout)
		err = c.c.notify(ctx, "notifications/initialized")
		cancel()
	}
	if err != nil {
		c.c.end()
		c.c = nil
		return err
	}
	return nil
}

func (c *mcpEventConn) call(timeout time.Duration, method string, params any) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	c.next++
	raw, err := c.c.call(ctx, c.next, method, params)
	if err != nil && ctx.Err() != nil {
		return nil, &mcpCheckFailure{kind: "timedOut"}
	}
	return raw, err
}

// listEvents is events/list, page by page.
func (c *mcpEventConn) listEvents(timeout time.Duration) ([]mcpEventDef, error) {
	var out []mcpEventDef
	cursor := ""
	for page := 0; page < mcpEventListPages; page++ {
		params := map[string]any{}
		if cursor != "" {
			params["cursor"] = cursor
		}
		raw, err := c.call(timeout, mcpEventsListMethod, params)
		if err != nil {
			return nil, err
		}
		var got struct {
			Events     []json.RawMessage `json:"events"`
			NextCursor string            `json:"nextCursor"`
		}
		if json.Unmarshal(raw, &got) != nil {
			return nil, &mcpCheckFailure{kind: "notMCP"}
		}
		for _, e := range got.Events {
			var def mcpEventDef
			if json.Unmarshal(e, &def) == nil && def.Name != "" {
				out = append(out, def)
			}
		}
		cursor = got.NextCursor
		if cursor == "" || len(out) >= mcpEventListLimit {
			break
		}
	}
	if len(out) > mcpEventListLimit {
		out = out[:mcpEventListLimit]
	}
	return out, nil
}

// poll is one events/poll; a nil cursor asks to start from now.
func (c *mcpEventConn) poll(timeout time.Duration, name string, arguments map[string]json.RawMessage, cursor *string) (mcpPollResult, error) {
	params := map[string]any{"name": name, "arguments": arguments, "cursor": cursor, "maxEvents": 50}
	raw, err := c.call(timeout, mcpEventsPollMethod, params)
	if err != nil {
		return mcpPollResult{}, err
	}
	var r mcpPollResult
	if json.Unmarshal(raw, &r) != nil {
		return mcpPollResult{}, &mcpCheckFailure{kind: "notMCP"}
	}
	return r, nil
}

func (p *mcpEventConns) forget(key string, c *mcpEventConn) {
	p.mu.Lock()
	if p.held[key] == c {
		delete(p.held, key)
	}
	p.mu.Unlock()
}

// drop ends one connection: it failed, or its entry changed.
func (p *mcpEventConns) drop(key string) {
	p.mu.Lock()
	c := p.held[key]
	delete(p.held, key)
	p.mu.Unlock()
	if c != nil {
		go c.end()
	}
}

func (c *mcpEventConn) end() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.c != nil {
		c.c.end()
		c.c = nil
	}
}

// keepOnly ends every connection no subscription names any more.
func (p *mcpEventConns) keepOnly(keys map[string]bool) {
	p.mu.Lock()
	var gone []string
	for k := range p.held {
		if !keys[k] {
			gone = append(gone, k)
		}
	}
	p.mu.Unlock()
	for _, k := range gone {
		p.drop(k)
	}
}

// endAll ends every connection: the host is stopping.
func (p *mcpEventConns) endAll() {
	p.mu.Lock()
	all := p.held
	p.held = map[string]*mcpEventConn{}
	p.mu.Unlock()
	var wg sync.WaitGroup
	for _, c := range all {
		wg.Add(1)
		go func() { defer wg.Done(); c.end() }()
	}
	wg.Wait()
}

// mcpEventsWords is DaemonCore.mcpWords.
func mcpEventsWords(e *mcpEventsError, server string) string {
	switch e.kind {
	case "transport":
		if e.message == mcpTooMany {
			return e.message
		}
		return "Can't reach " + server + ": " + strings.TrimSpace(e.message)
	case "timedOut":
		return "Can't reach " + server + ": it did not answer in 15 s."
	case "needsSignIn":
		return server + " wants a sign-in first."
	case "exhausted":
		return server + " asked to be asked less often."
	}
	return server + " answered with an error."
}

// mcpTheirWords is the server's own words after a colon, or a full stop.
func mcpTheirWords(message string) string {
	t := strings.TrimSpace(message)
	if t == "" {
		return "."
	}
	if r := []rune(t); len(r) > 200 {
		t = string(r[:200])
	}
	return ": " + t
}
