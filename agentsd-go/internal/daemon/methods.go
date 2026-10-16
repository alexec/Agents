package daemon

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func decode[T any](params json.RawMessage) (T, error) {
	var v T
	if len(params) == 0 || string(params) == "null" {
		return v, nil
	}
	return v, json.Unmarshal(params, &v)
}

func empty() any { return map[string]any{} }

// once does the work of a request with a sendID only the first time (the window resends for 30 s).
func (d *Daemon) once(sendID string) bool {
	if sendID == "" {
		return true
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.sent == nil {
		d.sent = map[string]bool{}
	}
	if d.sent[sendID] {
		return false
	}
	d.sent[sendID] = true
	return true
}

func (d *Daemon) register() {
	d.Handle("daemon/ping", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		return map[string]any{"ok": true}, nil
	})
	for _, m := range []string{"credentials/offer", "presence/report", "agents/prewarm", "agents/discardDraft",
		"retention/set", "clientPermissions/set", "person/set", "sandbox/set", "pool/applyAllowances",
		"files/watch", "files/unwatch"} {
		d.Handle(m, func(ctx context.Context, c *Client, p json.RawMessage) (any, error) { return empty(), nil })
	}
	d.Handle("permissions/pending", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		out := []PermissionRequest{}
		d.mu.Lock()
		ls := d.lives
		d.mu.Unlock()
		for _, l := range ls {
			l.mu.Lock()
			for _, pp := range l.pending {
				out = append(out, pp.req)
			}
			l.mu.Unlock()
		}
		return out, nil
	})
	d.Handle("elicitations/pending", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) { return []any{}, nil })
	d.Handle("runtimes/list", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) { return d.runtimesList(), nil })

	d.Handle("projects/list", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		out := []ProjectSummary{}
		for _, pr := range d.store.Projects() {
			out = append(out, *d.summary(pr))
		}
		// The window learns a server's workflows only from workflow/changed.
		go func() { time.Sleep(300 * time.Millisecond); d.tellWorkflows(c) }()
		return out, nil
	})
	d.Handle("projects/add", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, err := decode[struct {
			Folder string `json:"folder"`
		}](p)
		if err != nil || r.Folder == "" {
			return nil, invalid(err)
		}
		path := folderPath(r.Folder)
		if fi, err := os.Stat(path); err != nil || !fi.IsDir() {
			return nil, &RPCError{Code: -32004, Message: path + " is not a folder on this host"}
		}
		s := d.summary(d.store.AddProject(folderURL(path)))
		d.Broadcast("project/changed", s)
		if d.wf != nil {
			go d.rescanWorkflows()
		}
		return s, nil
	})
	d.Handle("projects/remove", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, _ := decode[struct {
			Folder string `json:"folder"`
		}](p)
		d.store.RemoveProject(folderURL(folderPath(r.Folder)))
		d.Broadcast("project/removed", map[string]any{"folder": r.Folder})
		return empty(), nil
	})

	d.Handle("agents/list", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, err := decode[struct {
			IncludeArchived *bool  `json:"includeArchived"`
			AgentID         string `json:"agentID"`
			Folder          string `json:"folder"`
			Limit           int    `json:"limit"`
			After           *struct {
				LastActivityAt Date   `json:"lastActivityAt"`
				ID             string `json:"id"`
			} `json:"after"`
		}](p)
		if err != nil {
			return nil, invalid(err)
		}
		if r.AgentID != "" {
			if a := d.store.Agent(r.AgentID); a != nil {
				return []Agent{*a}, nil
			}
			return []Agent{}, nil
		}
		limit := r.Limit
		if limit <= 0 {
			limit = 500
		}
		out := []Agent{}
		for _, a := range d.store.Agents() {
			if r.IncludeArchived != nil && !*r.IncludeArchived && a.ArchivedAt != nil {
				continue
			}
			if r.Folder != "" && folderPath(a.Cwd) != folderPath(r.Folder) {
				continue
			}
			if r.After != nil && (a.LastActivityAt > r.After.LastActivityAt || a.LastActivityAt == r.After.LastActivityAt && a.ID <= r.After.ID) {
				continue
			}
			out = append(out, a)
			if len(out) == limit {
				break
			}
		}
		return out, nil
	})
	d.Handle("agents/options", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		return map[string]any{"draftID": NewUUID(), "options": []any{}, "commands": []any{}}, nil
	})
	d.Handle("agents/start", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, err := decode[struct {
			RuntimeID    string `json:"runtimeID"`
			Cwd          string `json:"cwd"`
			Prompt       string `json:"prompt"`
			RequestID    string `json:"requestID"`
			StartOptions struct {
				Values map[string]any `json:"values"`
			} `json:"startOptions"`
		}](p)
		if err != nil || r.RuntimeID == "" || r.Cwd == "" {
			return nil, invalid(err)
		}
		if err := d.needsSignIn(r.RuntimeID); err != nil {
			return nil, err
		}
		return d.Start(r.RuntimeID, r.Cwd, r.Prompt, r.StartOptions.Values)
	})
	d.Handle("agents/prompt", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, err := decode[struct {
			AgentID string `json:"agentID"`
			Text    string `json:"text"`
			SendID  string `json:"sendID"`
		}](p)
		if err != nil || r.AgentID == "" {
			return nil, invalid(err)
		}
		a := d.store.Agent(r.AgentID)
		if a == nil {
			return nil, &RPCError{Code: -32005, Message: "no such agent"}
		}
		if err := d.needsSignIn(a.RuntimeID); err != nil {
			return nil, err
		}
		if d.once(r.SendID) {
			d.live(a.ID).enqueue(r.Text)
		}
		return empty(), nil
	})
	d.Handle("agents/stop", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, _ := decode[struct {
			AgentID string `json:"agentID"`
		}](p)
		a := d.store.Agent(r.AgentID)
		if a == nil {
			return nil, &RPCError{Code: -32005, Message: "no such agent"}
		}
		d.live(a.ID).cancel()
		return empty(), nil
	})
	d.Handle("agents/archive", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, _ := decode[struct {
			AgentID string `json:"agentID"`
		}](p)
		a := d.store.Agent(r.AgentID)
		if a == nil {
			return nil, &RPCError{Code: -32005, Message: "no such agent"}
		}
		l := d.live(a.ID)
		l.cancel()
		if l.session != nil {
			l.session.Stop()
		}
		now := Now()
		a = d.store.Agent(a.ID)
		a.ArchivedAt, a.State = &now, "archived"
		d.changed(a)
		return empty(), nil
	})
	d.Handle("agents/setUnread", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, _ := decode[struct {
			AgentID string `json:"agentID"`
			Unread  bool   `json:"unread"`
		}](p)
		if a := d.store.Agent(r.AgentID); a != nil {
			a.IsUnread = r.Unread
			d.store.SaveAgent(a)
			d.Broadcast("agent/changed", a)
		}
		return empty(), nil
	})
	d.Handle("agents/transcript", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, err := decode[struct {
			AgentID string `json:"agentID"`
			Before  *int   `json:"before"`
			Limit   *int   `json:"limit"`
			From    *int   `json:"from"`
		}](p)
		if err != nil {
			return nil, invalid(err)
		}
		t := d.store.Transcript(strings.ToUpper(r.AgentID))
		from, before, limit := 0, len(t), 200
		if r.From != nil {
			from = *r.From
		}
		if r.Before != nil && *r.Before < before {
			before = *r.Before
		}
		if r.Limit != nil {
			limit = min(*r.Limit, 1000)
		}
		if from < 0 || before < 0 || limit < 0 {
			return nil, invalid(nil)
		}
		start := max(from, before-limit)
		if start > before {
			start = before
		}
		return map[string]any{"firstIndex": start, "total": len(t), "entries": t[start:before]}, nil
	})
	d.Handle("agents/turns", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		return map[string]any{"turns": []any{}, "firstTurn": 0, "openStart": 0}, nil
	})
	d.Handle("permissions/answer", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, err := decode[struct {
			PermissionID string `json:"permissionID"`
			OptionID     string `json:"optionID"`
		}](p)
		if err != nil {
			return nil, invalid(err)
		}
		d.mu.Lock()
		ls := d.lives
		d.mu.Unlock()
		for _, l := range ls {
			if l.answer(r.PermissionID, r.OptionID) {
				return empty(), nil
			}
		}
		return nil, &RPCError{Code: -32602, Message: "no such question waiting"}
	})
	d.Handle("relay/offer", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		o, err := decode[relayOffer](p)
		if err != nil || o.Runtime == "" {
			return nil, invalid(err)
		}
		if err := d.offerRelay(o); err != nil {
			return nil, err
		}
		return empty(), nil
	})
	d.registerMore()
}

func (d *Daemon) summary(p Project) *ProjectSummary {
	path := folderPath(p.Folder)
	fi, err := os.Stat(path)
	s := &ProjectSummary{Project: p, Name: filepath.Base(path), Exists: err == nil && fi.IsDir(), LastActivityAt: p.AddedAt,
		Counts: map[string]int{}, CostToDate: map[string]any{}}
	for _, a := range d.store.Agents() {
		if folderPath(a.Cwd) != path {
			continue
		}
		s.Counts[a.group()]++
		if a.LastActivityAt > s.LastActivityAt {
			s.LastActivityAt = a.LastActivityAt
		}
	}
	return s
}

func (d *Daemon) summaryFor(cwd string) *ProjectSummary {
	for _, p := range d.store.Projects() {
		if folderPath(p.Folder) == folderPath(cwd) {
			return d.summary(p)
		}
	}
	return nil
}
