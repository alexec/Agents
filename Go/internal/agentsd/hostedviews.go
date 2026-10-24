package agentsd

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	sdk "github.com/coder/acp-go-sdk"
)

// Views of a hosted server (#1341), as the Swift host had them (#717): through its one copy,
// not a second one. Views are one more user of the copy, for viewLinger after their last
// request, so a page that calls a tool again finds it running. A session reaching the copy
// over /mcp/hosted is never offered, and can't call, a tool that only a view may call
// (visibility ["app"]): merging and approving stay a person's.

// viewLinger is how long views keep a hosted copy after their last request.
var viewLinger = 2 * time.Minute

// hostedViewConnect is the way to server's hosted copy for a view, for viewServer.connect.
func (d *Daemon) hostedViewConnect(server sdk.McpServerStdio, folder *string, cwd string) func() (mcpConn, error) {
	return func() (mcpConn, error) {
		scope := "~"
		if folder != nil {
			scope = *folder
		}
		user := "views " + scope + " " + server.Name
		path, err := d.hostedUse(server, folder, cwd, user)
		if err != nil {
			return nil, &mcpCheckFailure{kind: "refused", message: server.Name + " can't start: " + err.Error() + "."}
		}
		d.hostedMu.Lock()
		h := d.hostedByRoute[strings.TrimPrefix(path, hostedPathPrefix)]
		if d.hostedViewTimers == nil {
			d.hostedViewTimers = map[string]*time.Timer{}
		}
		if t := d.hostedViewTimers[user]; t != nil {
			t.Stop()
		}
		d.hostedViewTimers[user] = time.AfterFunc(viewLinger, func() {
			d.hostedMu.Lock()
			delete(d.hostedViewTimers, user)
			d.hostedMu.Unlock()
			d.hostedRelease(user)
		})
		d.hostedMu.Unlock()
		if h == nil {
			return nil, &mcpCheckFailure{kind: "stopped", message: server.Name + " stopped."}
		}
		return &hostedViewConn{d: d, h: h}, nil
	}
}

// hostedViewConn is mcpConn over a hosted copy: each request goes through hostedCall.
type hostedViewConn struct {
	d *Daemon
	h *hostedServer
}

func (c *hostedViewConn) call(ctx context.Context, _ int, method string, params any) (json.RawMessage, error) {
	raw, err := json.Marshal(params)
	if err != nil {
		return nil, &mcpCheckFailure{kind: "notMCP"}
	}
	type answer struct {
		result json.RawMessage
		err    *Error
	}
	done := make(chan answer, 1)
	go func() {
		r, e := c.d.hostedCall(c.h, method, raw)
		done <- answer{r, e}
	}()
	select {
	case a := <-done:
		if a.err != nil {
			return nil, &mcpCheckFailure{kind: "refused", message: a.err.Message, code: a.err.Code}
		}
		return a.result, nil
	case <-ctx.Done():
		return nil, &mcpCheckFailure{kind: "timedOut"}
	}
}

// notify: the host is the copy's one client, and has initialized it already.
func (c *hostedViewConn) notify(context.Context, string) error { return nil }

// end: the copy stays for viewLinger.
func (c *hostedViewConn) end() {}

// MARK: Tools only a view may call

// viewOnlyTools are the names in a tools/list result whose visibility leaves out the model.
func viewOnlyTools(result json.RawMessage) map[string]bool {
	var list struct {
		Tools []struct {
			Name string `json:"name"`
			Meta struct {
				UI struct {
					Visibility []string `json:"visibility"`
				} `json:"ui"`
			} `json:"_meta"`
		} `json:"tools"`
	}
	only := map[string]bool{}
	if json.Unmarshal(result, &list) != nil {
		return only
	}
	for _, t := range list.Tools {
		if v := t.Meta.UI.Visibility; len(v) > 0 && !contains(v, "model") {
			only[t.Name] = true
		}
	}
	return only
}

// withoutViewOnlyTools is a tools/list result without the tools only a view may call.
func withoutViewOnlyTools(result json.RawMessage, only map[string]bool) json.RawMessage {
	if len(only) == 0 {
		return result
	}
	var shape map[string]json.RawMessage
	var tools []json.RawMessage
	if json.Unmarshal(result, &shape) != nil || json.Unmarshal(shape["tools"], &tools) != nil {
		return result
	}
	kept := make([]json.RawMessage, 0, len(tools))
	for _, t := range tools {
		var named struct {
			Name string `json:"name"`
		}
		json.Unmarshal(t, &named)
		if !only[named.Name] {
			kept = append(kept, t)
		}
	}
	shape["tools"], _ = json.Marshal(kept)
	b, err := json.Marshal(shape)
	if err != nil {
		return result
	}
	return b
}

// hostedSessionCall is hostedCall for a session: tools only a view may call are not listed,
// and calling one is refused.
func (d *Daemon) hostedSessionCall(h *hostedServer, method string, params json.RawMessage) (json.RawMessage, *Error) {
	switch method {
	case "tools/list":
		result, err := d.hostedCall(h, method, params)
		if err != nil {
			return nil, err
		}
		only := viewOnlyTools(result)
		d.hostedMu.Lock()
		h.viewOnly = only
		d.hostedMu.Unlock()
		return withoutViewOnlyTools(result, only), nil
	case "tools/call":
		var call struct {
			Name string `json:"name"`
		}
		json.Unmarshal(params, &call)
		d.hostedMu.Lock()
		only := h.viewOnly
		d.hostedMu.Unlock()
		if only == nil {
			result, err := d.hostedCall(h, "tools/list", json.RawMessage(`{}`))
			if err != nil {
				return nil, err
			}
			only = viewOnlyTools(result)
			d.hostedMu.Lock()
			h.viewOnly = only
			d.hostedMu.Unlock()
		}
		if only[call.Name] {
			return nil, &Error{Code: -32602, Message: "Unknown tool: " + call.Name + " is a view's only; a person uses it."}
		}
	}
	return d.hostedCall(h, method, params)
}
