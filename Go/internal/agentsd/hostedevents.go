package agentsd

import (
	"context"
	"strings"
)

// Events of a hosted server (#4516): through its one copy, as its views are (#1341), so a
// hosted entry is one process on this host, not one for the sessions and one for the event
// subscriptions. The subscriptions are one more user of the copy while their connection is
// open, and are told what the copy says of its events.

// hostedEventConnect is the way to s's hosted copy for its event subscriptions.
func (d *Daemon) hostedEventConnect(s eventServer, heard func(string)) (mcpConn, error) {
	var folder *string
	if s.scope != "~" {
		folder = &s.scope
	}
	user := "events " + s.pool()
	path, err := d.hostedUse(*s.filled.Stdio, folder, s.cwd, user)
	if err != nil {
		return nil, err
	}
	d.hostedMu.Lock()
	h := d.hostedByRoute[strings.TrimPrefix(path, hostedPathPrefix)]
	if h != nil {
		if h.heard == nil {
			h.heard = map[string]func(string){}
		}
		h.heard[user] = heard
	}
	d.hostedMu.Unlock()
	if h == nil {
		d.hostedRelease(user)
		return nil, &mcpCheckFailure{kind: "stopped", message: s.name + " stopped."}
	}
	return &hostedEventConn{hostedViewConn: hostedViewConn{d: d, h: h}, user: user}, nil
}

// hostedEventConn is mcpConn over a hosted copy for event subscriptions; ending it lets the
// copy go when nothing else uses it.
type hostedEventConn struct {
	hostedViewConn
	user string
}

// notify: the host is the copy's one client, and has initialized it already.
func (c *hostedEventConn) notify(context.Context, string) error { return nil }

func (c *hostedEventConn) end() { c.d.hostedRelease(c.user) }
