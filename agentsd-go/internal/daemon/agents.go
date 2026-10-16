package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/url"
	"strings"
	"sync"
	"time"
	"unicode"

	acp "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/agentsd-go/internal/runtime"
)

// live is an agent with a runtime behind it.
type live struct {
	d       *Daemon
	id      string
	mu      sync.Mutex
	session *runtime.Session
	queue   []string
	running bool
	pending map[string]*pendingPermission
	plans   map[string]any
	stop    context.CancelFunc
}

type pendingPermission struct {
	req    PermissionRequest
	answer chan string
}

func (d *Daemon) live(id string) *live {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.lives == nil {
		d.lives = map[string]*live{}
	}
	l := d.lives[id]
	if l == nil {
		l = &live{d: d, id: id, pending: map[string]*pendingPermission{}, plans: map[string]any{}}
		d.lives[id] = l
	}
	return l
}

// folderPath is the path of a file URL.
func folderPath(folder string) string {
	if u, err := url.Parse(folder); err == nil && u.Scheme == "file" {
		return strings.TrimSuffix(u.Path, "/")
	}
	return strings.TrimSuffix(folder, "/")
}

func folderURL(path string) string {
	return (&url.URL{Scheme: "file", Path: strings.TrimSuffix(path, "/") + "/"}).String()
}

// record appends an entry, and tells every client.
func (d *Daemon) record(id string, e Entry) {
	n := d.store.Append(id, e)
	d.Broadcast("agent/entry", map[string]any{"agentID": id, "entry": e, "index": n})
}

func (d *Daemon) changed(a *Agent) {
	a.LastActivityAt = Now()
	d.store.SaveAgent(a)
	d.Broadcast("agent/changed", a)
	if p := d.summaryFor(a.Cwd); p != nil {
		d.Broadcast("project/changed", p)
	}
}

func (d *Daemon) setState(id, state, reason string) {
	a := d.store.Agent(id)
	if a == nil {
		return
	}
	a.State = state
	a.EndedReason = reason
	if state == "finished" || state == "stopped" {
		a.IsUnread = state == "finished"
	} else {
		a.Report = nil
	}
	d.changed(a)
	body := map[string]any{"_0": state}
	if reason != "" {
		body["reason"] = reason
	}
	d.record(id, entry("stateChanged", body))
}

// Start makes an agent and runs its first turn.
func (d *Daemon) Start(runtimeID, cwd, prompt string, options map[string]any) (string, error) {
	return d.startAs(runtimeID, cwd, prompt, func(a *Agent) { a.StartOptions.Values = orValues(options) })
}

func orValues(v map[string]any) map[string]any {
	if v == nil {
		return map[string]any{}
	}
	return v
}

// startAs makes an agent, lets the caller set what it was started as, and runs its first turn.
func (d *Daemon) startAs(runtimeID, cwd, prompt string, as func(*Agent)) (string, error) {
	var options map[string]any
	rt := d.catalog(runtimeID)
	if rt == nil {
		return "", &RPCError{Code: -32602, Message: "no runtime " + runtimeID}
	}
	if options == nil {
		options = map[string]any{}
	}
	a := &Agent{
		ID: NewUUID(), RuntimeID: runtimeID, Cwd: folderURL(folderPath(cwd)), State: "starting",
		Title:        titleFrom(prompt),
		StartOptions: StartOptions{Values: options, ExtraArguments: []string{}},
		AdvertisedOptions: json.RawMessage("[]"), AvailableCommands: json.RawMessage("[]"),
		CreatedAt: Now(), LastActivityAt: Now(),
	}
	if as != nil {
		as(a)
	}
	d.changed(a)
	l := d.live(a.ID)
	l.enqueue(prompt)
	return a.ID, nil
}

func titleFrom(prompt string) string {
	t := strings.TrimSpace(strings.SplitN(prompt, "\n", 2)[0])
	if r := []rune(t); len(r) > 60 {
		t = string(r[:60]) + "…"
	}
	return t
}

func (l *live) enqueue(text string) {
	l.mu.Lock()
	l.queue = append(l.queue, text)
	start := !l.running
	l.running = true
	l.mu.Unlock()
	if start {
		go l.run()
	}
}

// run takes prompts off the queue, one turn at a time.
func (l *live) run() {
	for {
		l.mu.Lock()
		if len(l.queue) == 0 {
			l.running = false
			l.mu.Unlock()
			return
		}
		text := l.queue[0]
		l.queue = l.queue[1:]
		l.mu.Unlock()
		l.turn(text)
	}
}

func (l *live) turn(text string) {
	d := l.d
	d.turnRunning(true)
	defer d.turnRunning(false)
	d.record(l.id, entry("userMessage", map[string]any{"_0": text}))
	d.setState(l.id, "running", "")
	a := d.store.Agent(l.id)
	ctx, cancel := context.WithCancel(d.ctx)
	l.mu.Lock()
	l.stop = cancel
	l.mu.Unlock()
	defer cancel()

	if l.session == nil {
		rt := d.catalog(a.RuntimeID)
		launch, err := d.launchFor(rt, folderPath(a.Cwd))
		if err != nil {
			d.record(l.id, entry("notice", map[string]any{"_0": map[string]any{"severity": "error", "title": "The runtime did not start", "detail": err.Error()}}))
			d.end(l.id, "stopped", "runtimeError", "")
			return
		}
		d.record(l.id, entry("runtimeNote", map[string]any{"_0": "Starting " + rt.Name + "…"}))
		s, err := runtime.Start(ctx, launch, l, d.mcpServersFor(l.id), d.sessionMeta(a.RuntimeID))
		if err != nil {
			log.Printf("agent %s: %v", l.id, err)
			d.record(l.id, entry("notice", map[string]any{"_0": map[string]any{"severity": "error", "title": "The runtime did not start", "detail": err.Error()}}))
			d.end(l.id, "stopped", "processDied", "")
			return
		}
		l.session = s
		a = d.store.Agent(l.id)
		a.RuntimeSessionID = string(s.ID)
		if opts, err := json.Marshal(s.NewResult.ConfigOptions); err == nil && string(opts) != "null" {
			a.AdvertisedOptions = opts
		}
		d.changed(a)
		go func() {
			<-s.Done()
			l.mu.Lock()
			if l.session == s {
				l.session = nil
			}
			l.mu.Unlock()
		}()
		// The start options the window chose (model, mode) go first.
		for k, v := range a.StartOptions.Values {
			if sv, ok := v.(string); ok && sv != "" {
				if err := s.SetConfig(ctx, k, sv); err != nil {
					log.Printf("agent %s: set %s=%s: %v", l.id, k, sv, err)
				}
			}
		}
	}
	r, err := l.session.Prompt(ctx, text)
	if err != nil {
		if ctx.Err() != nil {
			d.end(l.id, "stopped", "cancelled", "")
			return
		}
		log.Printf("agent %s: prompt: %v", l.id, err)
		d.record(l.id, entry("notice", map[string]any{"_0": map[string]any{"severity": "error", "title": "The turn failed", "detail": err.Error()}}))
		select {
		case <-l.session.Done():
			l.session = nil
			d.end(l.id, "stopped", "processDied", "")
		default:
			d.end(l.id, "stopped", "runtimeError", "")
		}
		return
	}
	if r.Usage != nil {
		d.record(l.id, entry("usageRecorded", map[string]any{"_0": map[string]any{
			"totalTokens": r.Usage.TotalTokens, "inputTokens": r.Usage.InputTokens, "outputTokens": r.Usage.OutputTokens}}))
	}
	switch r.StopReason {
	case acp.StopReasonEndTurn:
		d.end(l.id, "finished", "endTurn", l.lastWords())
	case acp.StopReasonCancelled:
		d.end(l.id, "stopped", "cancelled", "")
	case acp.StopReasonMaxTokens:
		d.end(l.id, "stopped", "maxTokens", "")
	case acp.StopReasonMaxTurnRequests:
		d.end(l.id, "stopped", "maxTurnRequests", "")
	case acp.StopReasonRefusal:
		d.end(l.id, "stopped", "refusal", "")
	default:
		d.end(l.id, "stopped", "unrecognised", "")
	}
}

// end closes a turn: the state, its reason, and a report derived from the last words
// (DaemonCore+DerivedEnding.swift): needs_answer when a card is open or the last
// sentence asks, else done with the first sentence.
func (d *Daemon) end(id, state, reason, last string) {
	a := d.store.Agent(id)
	if a == nil {
		return
	}
	a.State, a.EndedReason = state, reason
	a.IsUnread = state == "finished"
	if state == "finished" {
		outcome, message := "done", firstSentence(last)
		if strings.HasSuffix(strings.TrimSpace(last), "?") {
			outcome = "needs_answer"
		}
		if message == "" {
			message = "Finished."
		}
		a.Report = &WorkReport{Outcome: outcome, Message: message, At: Now()}
	}
	d.changed(a)
	body := map[string]any{"_0": state, "reason": reason}
	d.record(id, entry("stateChanged", body))
	d.workflowAgentEnded(a)
}

func firstSentence(s string) string {
	// Code is not a sentence: leave fenced blocks out.
	var prose []string
	fenced := false
	for _, line := range strings.Split(s, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "```") {
			fenced = !fenced
			continue
		}
		if !fenced && strings.TrimSpace(line) != "" {
			prose = append(prose, line)
		}
	}
	s = strings.TrimSpace(strings.Join(prose, "\n"))
	for i, r := range s {
		if (r == '.' || r == '!' || r == '?') && (i+1 == len(s) || unicode.IsSpace(rune(s[i+1]))) {
			return s[:i+1]
		}
		if r == '\n' {
			return strings.TrimSpace(s[:i])
		}
	}
	if r := []rune(s); len(r) > 200 {
		return string(r[:200]) + "…"
	}
	return s
}

// lastWords is the text of the agent's last message in this turn.
func (l *live) lastWords() string {
	t := l.d.store.Transcript(l.id)
	var b strings.Builder
	id := ""
	for i := len(t) - 1; i >= 0; i-- {
		k := t[i].Kind
		if m, ok := k["agentMessage"].(map[string]any); ok {
			mid, _ := m["messageID"].(string)
			if b.Len() > 0 && mid != id {
				break
			}
			id = mid
			s, _ := m["text"].(string)
			b.WriteString(reverse(s))
			continue
		}
		if _, ok := k["userMessage"]; ok {
			break
		}
		if b.Len() > 0 {
			break
		}
	}
	return reverse(b.String())
}

func reverse(s string) string {
	r := []rune(s)
	for i, j := 0, len(r)-1; i < j; i, j = i+1, j-1 {
		r[i], r[j] = r[j], r[i]
	}
	return string(r)
}

// MARK: runtime.Sink

// toolCall turns ACP's tool call JSON into the Swift ToolCall's keys.
func toolCall(raw map[string]any) map[string]any {
	out := map[string]any{"content": []any{}, "locations": []any{}}
	for k, v := range raw {
		switch k {
		case "sessionUpdate", "_meta":
		case "toolCallId":
			out["toolCallID"] = v
		default:
			if v != nil {
				out[k] = v
			}
		}
	}
	return out
}

func (l *live) Update(n acp.SessionNotification) {
	d := l.d
	b, err := json.Marshal(n.Update)
	if err != nil {
		return
	}
	var u map[string]any
	if json.Unmarshal(b, &u) != nil {
		return
	}
	kind, _ := u["sessionUpdate"].(string)
	switch kind {
	case "agent_message_chunk", "agent_thought_chunk":
		c, _ := u["content"].(map[string]any)
		text, _ := c["text"].(string)
		if text == "" {
			return
		}
		body := map[string]any{"text": text}
		if id, ok := u["messageId"].(string); ok {
			body["messageID"] = id
		}
		name := "agentMessage"
		if kind == "agent_thought_chunk" {
			name = "agentThought"
		}
		d.record(l.id, entry(name, body))
	case "tool_call":
		d.record(l.id, entry("toolCall", map[string]any{"_0": toolCall(u)}))
	case "tool_call_update":
		d.record(l.id, entry("toolCallUpdate", map[string]any{"_0": toolCall(u)}))
	case "plan":
		plan := map[string]any{"planID": "plan", "entries": u["entries"], "state": "current", "at": Now()}
		l.mu.Lock()
		l.plans["plan"] = plan
		plans := []any{plan}
		l.mu.Unlock()
		a := d.store.Agent(l.id)
		a.Plans, _ = json.Marshal(plans)
		d.changed(a)
		d.record(l.id, entry("planUpdated", map[string]any{"_0": plan}))
	case "current_mode_update":
		d.record(l.id, entry("optionChanged", map[string]any{"id": "mode", "value": u["currentModeId"]}))
	case "config_option_update":
		a := d.store.Agent(l.id)
		if opts, err := json.Marshal(u["configOptions"]); err == nil {
			a.AdvertisedOptions = opts
			d.changed(a)
		}
	case "available_commands_update":
		a := d.store.Agent(l.id)
		if cmds, err := json.Marshal(u["availableCommands"]); err == nil {
			a.AvailableCommands = cmds
			d.changed(a)
		}
	case "session_info_update":
		if t, ok := u["title"].(string); ok && t != "" {
			a := d.store.Agent(l.id)
			a.Title = t
			d.changed(a)
		}
	case "usage_update":
		used, _ := u["used"].(float64)
		size, _ := u["size"].(float64)
		usage := map[string]any{"used": int(used), "size": int(size), "at": Now()}
		d.Broadcast("agent/usage", map[string]any{"agentID": l.id, "usage": usage})
	default:
		log.Printf("agent %s: update not drawn: %s", l.id, kind)
	}
}

func (l *live) Permission(ctx context.Context, p acp.RequestPermissionRequest) string {
	d := l.d
	raw, _ := json.Marshal(p.ToolCall)
	var tc map[string]any
	json.Unmarshal(raw, &tc)
	req := PermissionRequest{ID: NewUUID(), AgentID: l.id, ToolCall: toolCall(tc), AskedAt: Now()}
	for _, o := range p.Options {
		req.Options = append(req.Options, PermissionOption{OptionID: string(o.OptionId), Name: o.Name, Kind: string(o.Kind)})
	}
	// The app's own tools are allowed with no question, as the Swift host does.
	if title, _ := tc["title"].(string); strings.HasPrefix(title, "mcp__agents__") {
		for _, o := range req.Options {
			if o.Kind == "allow_always" || o.Kind == "allow_once" {
				return o.OptionID
			}
		}
	}
	pp := &pendingPermission{req: req, answer: make(chan string, 1)}
	l.mu.Lock()
	l.pending[req.ID] = pp
	l.mu.Unlock()
	d.record(l.id, entry("permissionAsked", map[string]any{"_0": req}))
	d.setStateQuiet(l.id, "waitingOnUser")
	d.Broadcast("agent/permission", map[string]any{"agentID": l.id, "request": req, "requestID": req.ID})
	var option string
	select {
	case option = <-pp.answer:
	case <-ctx.Done():
	}
	l.mu.Lock()
	delete(l.pending, req.ID)
	l.mu.Unlock()
	name := option
	for _, o := range req.Options {
		if o.OptionID == option {
			name = o.Name
		}
	}
	if option != "" {
		d.record(l.id, entry("permissionAnswered", map[string]any{"optionID": option, "optionName": name}))
	}
	d.Broadcast("agent/permission", map[string]any{"agentID": l.id, "requestID": req.ID})
	d.setStateQuiet(l.id, "running")
	return option
}

func (d *Daemon) setStateQuiet(id, state string) {
	a := d.store.Agent(id)
	if a == nil || a.State == state {
		return
	}
	a.State = state
	d.changed(a)
	d.record(id, entry("stateChanged", map[string]any{"_0": state}))
}

func (l *live) Served(kind, detail string) {
	log.Printf("agent %s: served %s %s", l.id, kind, detail)
}

func (l *live) answer(permissionID, option string) bool {
	l.mu.Lock()
	pp := l.pending[permissionID]
	l.mu.Unlock()
	if pp == nil {
		return false
	}
	known := false
	for _, o := range pp.req.Options {
		known = known || o.OptionID == option
	}
	if !known {
		return false
	}
	select {
	case pp.answer <- option:
	default:
	}
	return true
}

func (l *live) cancel() {
	l.mu.Lock()
	s, stop := l.session, l.stop
	l.queue = nil
	l.mu.Unlock()
	if s != nil {
		ctx, c := context.WithTimeout(context.Background(), 5*time.Second)
		defer c()
		if err := s.Cancel(ctx); err != nil && stop != nil {
			stop()
		}
	}
	// No answer will come to an open card.
	l.mu.Lock()
	for _, pp := range l.pending {
		select {
		case pp.answer <- "":
		default:
		}
	}
	l.mu.Unlock()
}

func (d *Daemon) stopAll() {
	d.mu.Lock()
	ls := make([]*live, 0, len(d.lives))
	for _, l := range d.lives {
		ls = append(ls, l)
	}
	d.mu.Unlock()
	for _, l := range ls {
		if l.session != nil {
			l.session.Stop()
		}
	}
}

var _ = fmt.Sprintf
