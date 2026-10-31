package agentsd

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Views drawn from ui:// resources (#187, MCP Apps) and from people's own MCP servers
// (#191): DaemonCore+AppViews and DaemonCore+ThirdPartyViews. What a drawn view asks for —
// its resource, a tool only a view may call, a log line, context for the agent — comes
// back here through views/*, naming the conversation.
//
// The app's own server offers views only to tests (AGENTS_TEST_VIEWS=1 on the Swift host);
// this host offers none, so the app's own views/read and views/call refuse, and
// views/toolCall answers that there is no such tool.

// viewBook is the views' state: catalogs, the calls being shown, and context kept.
type viewBook struct {
	viewMu       sync.Mutex
	viewCatalogs map[string]viewCatalog
	viewFailures map[string]time.Time
	viewLoads    map[string]chan struct{}
	// viewCalls is each agent's calls of a person's server's tools, by tool call id.
	viewCalls map[wire.UUID]map[string]*thirdPartyCall
	// viewOwners is the agent and server each view was written for.
	viewOwners map[wire.UUID]viewOwner
	// viewContexts is each agent's views' last context, told with the next message.
	viewContexts map[wire.UUID]map[wire.UUID]string
}

type viewOwner struct {
	agent  wire.UUID
	server string
}

// thirdPartyCall is one call of a person's server's tool, as the runtime has told it so far.
type thirdPartyCall struct {
	candidates []shapeCandidate
	// viewID is made once, so the call's entries share it however they race.
	viewID wire.UUID
	view   *wire.AppViewCall
	call   wire.ToolCall
}

// viewHTML is the one kind of view there is so far.
const viewHTML = "text/html;profile=mcp-app"

// viewContextLimit is the most of a view's context told to the agent, in characters.
const viewContextLimit = 8000

func viewRefused(msg string) error { return &Error{Code: wire.FailureViewRefused, Message: msg} }

func (d *Daemon) registerViews() {
	On(d, wire.CallViewsRead, func(ctx context.Context, c *Client, r wire.ViewReadRequest) (wire.ViewResource, error) {
		return d.readView(ctx, r)
	})
	On(d, wire.CallViewsCall, func(ctx context.Context, c *Client, r wire.ViewCallRequest) (wire.JSONValue, error) {
		return d.callFromView(ctx, r)
	})
	On(d, wire.CallViewsLog, func(ctx context.Context, c *Client, r wire.ViewLogRequest) (wire.Empty, error) {
		d.logFromView(r)
		return wire.Empty{}, nil
	})
	On(d, wire.CallViewsContext, func(ctx context.Context, c *Client, r wire.ViewContextRequest) (wire.Empty, error) {
		return wire.Empty{}, d.keepViewContext(r)
	})
	On(d, wire.CallViewsShow, func(ctx context.Context, c *Client, r wire.ViewShowRequest) (wire.Empty, error) {
		return wire.Empty{}, d.answerViewShow(r)
	})
	On(d, wire.CallViewsToolCall, func(ctx context.Context, c *Client, r wire.ViewToolCallRequest) (wire.JSONValue, error) {
		return d.viewToolCall(r)
	})
}

// MARK: An agent's call

// viewToolCall is an agent calling one of the agents server's tools that has a view: this
// host's server has none.
func (d *Daemon) viewToolCall(r wire.ViewToolCallRequest) (wire.JSONValue, error) {
	d.appMu.Lock()
	g := d.appTokens[r.Token]
	d.appMu.Unlock()
	if g == nil || d.Store.Agent(g.agent) == nil {
		return nil, &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was shown."}
	}
	return nil, viewRefused("No tool called " + r.Name + ".")
}

// noteViewToolCall is a tool call from the runtime: if it is a call of a person's server's
// tool with a view, its appView entry, written as it starts (when the runtime named the
// server outright) and again when it is answered. The app never calls the tool itself.
func (d *Daemon) noteViewToolCall(agentID wire.UUID, folder string, incoming wire.ToolCall) {
	if incoming.ToolCallID == nil {
		return
	}
	id := *incoming.ToolCallID
	d.viewMu.Lock()
	calls := d.viewCalls[agentID]
	known := calls[id]
	d.viewMu.Unlock()
	if known == nil {
		names := d.viewServerNames(folder)
		if len(names) == 0 {
			return
		}
		candidates := shapeCandidates(incoming, names)
		if len(candidates) == 0 {
			return
		}
		known = &thirdPartyCall{candidates: candidates, viewID: store.NewUUID(), call: incoming}
	}
	d.viewMu.Lock()
	if d.viewCalls == nil {
		d.viewCalls, d.viewOwners = map[wire.UUID]map[string]*thirdPartyCall{}, map[wire.UUID]viewOwner{}
	}
	if d.viewCalls[agentID] == nil {
		d.viewCalls[agentID] = map[string]*thirdPartyCall{}
	}
	calls = d.viewCalls[agentID]
	if held := calls[id]; held != nil {
		known = held
		known.call = mergedCall(known.call, incoming)
	}
	if len(known.candidates) == 0 {
		d.viewMu.Unlock()
		return
	}
	calls[id] = known
	// Bounded: the last few calls an agent made are all that can still be answered.
	if len(calls) > 64 {
		keys := make([]string, 0, len(calls))
		for k := range calls {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		if keys[0] != id {
			delete(calls, keys[0])
		}
	}
	d.viewMu.Unlock()
	go d.writeThirdPartyView(id, agentID, folder)
}

// noteAgentViewCall is noteViewToolCall for a call in agentID's turn, in its folder.
func (d *Daemon) noteAgentViewCall(agentID wire.UUID, call wire.ToolCall) {
	if a := d.Store.Agent(agentID); a != nil {
		d.noteViewToolCall(agentID, folderPath(a), call)
	}
}

// mergedCall is the later update over the earlier: a field it leaves out keeps what was there.
func mergedCall(old, upd wire.ToolCall) wire.ToolCall {
	call := old
	if upd.Title != "Tool call" {
		call.Title = upd.Title
	}
	if upd.Name != nil {
		call.Name = upd.Name
	}
	if upd.Status != nil {
		call.Status = upd.Status
	}
	if !isNull(upd.RawInput) {
		call.RawInput = upd.RawInput
	}
	if !isNull(upd.RawOutput) {
		call.RawOutput = upd.RawOutput
	}
	return call
}

func (d *Daemon) writeThirdPartyView(id string, agentID wire.UUID, folder string) {
	d.viewMu.Lock()
	first := d.viewCalls[agentID][id]
	var candidates []shapeCandidate
	if first != nil {
		candidates = append(candidates, first.candidates...)
	}
	d.viewMu.Unlock()
	if len(candidates) == 0 {
		return
	}
	// Which reading names a tool with a view, by the server's own catalog.
	var chosen *shapeCandidate
	var tool viewTool
	for i, c := range candidates {
		s, problem := d.viewServerFor(c.server, folder)
		if problem != 0 {
			continue
		}
		catalog := d.loadViewCatalog(context.Background(), s)
		if catalog == nil {
			continue
		}
		if t := catalog.tool(c.tool); t != nil {
			chosen, tool = &candidates[i], *t
			break
		}
	}
	d.viewMu.Lock()
	// As it stands now: other updates may have come while the catalog was read.
	latest := d.viewCalls[agentID][id]
	if latest == nil {
		d.viewMu.Unlock()
		return
	}
	if chosen == nil {
		latest.candidates = nil
		d.viewMu.Unlock()
		return
	}
	var view wire.AppViewCall
	if latest.view != nil {
		view = *latest.view
	} else {
		view = wire.AppViewCall{ID: latest.viewID, Server: chosen.server, Tool: tool.Name, ResourceUri: tool.ResourceURI,
			Arguments: chosen.arguments, State: wire.AppViewCallStateRunning}
		if tool.feedsPins() {
			yes := true
			view.Pinnable = &yes
		}
	}
	if result, ok := shapeResultOf(latest.call); ok {
		// A text-only result is not drawn in the chat (Q7); a call already shown running
		// still gets its answer.
		if !result.drawable && latest.view == nil {
			latest.candidates = nil
			d.viewMu.Unlock()
			log.Printf("mcp views: %s's %s answered in text only: not drawn inline", chosen.server, tool.Name)
			return
		}
		view.Result, view.State = result.value, wire.AppViewCallStateDone
	} else if !chosen.exact || latest.view != nil {
		// A joined title is only trusted once there is a result to draw from, and a call
		// is shown running once.
		d.viewMu.Unlock()
		return
	}
	if latest.view != nil && (latest.view.State == wire.AppViewCallStateDone || sameView(*latest.view, view)) {
		d.viewMu.Unlock()
		return
	}
	latest.view = &view
	d.viewOwners[view.ID] = viewOwner{agent: agentID, server: chosen.server}
	d.boundViewOwners(view.ID)
	// Written under the lock, so a running entry never lands after its answer.
	d.record(agentID, wire.TranscriptEntryKind{AppView: &wire.TranscriptEntryKindAppView{Value: view}})
	d.viewMu.Unlock()
}

func sameView(a, b wire.AppViewCall) bool {
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return bytes.Equal(x, y)
}

// boundViewOwners keeps at most 512, never keep's. viewMu is held.
func (d *Daemon) boundViewOwners(keep wire.UUID) {
	if len(d.viewOwners) <= 512 {
		return
	}
	for k := range d.viewOwners {
		if k != keep {
			delete(d.viewOwners, k)
			return
		}
	}
}

// viewServerOf is the server whose view viewID is in agentID's chat: kept as it was
// written, or found in the record after a restart. "" for the app's own views.
func (d *Daemon) viewServerOf(viewID, agentID wire.UUID) string {
	d.viewMu.Lock()
	known, ok := d.viewOwners[viewID]
	d.viewMu.Unlock()
	if ok {
		if known.agent == agentID && known.server != appServerName {
			return known.server
		}
		return ""
	}
	if d.Store.Agent(agentID) == nil {
		return ""
	}
	server := appServerName
	entries, _, _ := d.Store.Transcript(agentID, 0)
	for i := len(entries) - 1; i >= 0; i-- {
		if v := entries[i].Kind.AppView; v != nil && v.Value.ID == viewID {
			server = v.Value.Server
			break
		}
	}
	// Kept either way, so the app's own views are looked up once.
	d.viewMu.Lock()
	if d.viewOwners == nil {
		d.viewCalls, d.viewOwners = map[wire.UUID]map[string]*thirdPartyCall{}, map[wire.UUID]viewOwner{}
	}
	d.viewOwners[viewID] = viewOwner{agent: agentID, server: server}
	d.boundViewOwners(viewID)
	d.viewMu.Unlock()
	if server == appServerName {
		return ""
	}
	return server
}

// MARK: What a drawn view asks for

// viewFolder is the folder a view's request is for: its agent's, or the pin's.
func (d *Daemon) viewFolder(agentID wire.UUID, claimed *wire.URL) (string, error) {
	if a := d.Store.Agent(agentID); a != nil {
		folder := filepath.Clean(folderPath(a))
		if claimed != nil && filepath.Clean(store.FolderPath(*claimed)) != folder {
			return "", viewRefused("That view is outside its folder.")
		}
		return folder, nil
	}
	if claimed != nil {
		if p := filepath.Clean(store.FolderPath(*claimed)); d.isFolderPath(p) {
			return p, nil
		}
	}
	return "", &Error{Code: CodeNoSuchAgent, Message: "That view has no folder."}
}

func (d *Daemon) readyViewServer(name, folder string) (viewServer, error) {
	s, problem := d.viewServerFor(name, folder)
	if problem != 0 {
		log.Printf("mcp views: %s's view not shown: %s", name, problem.pinReason())
		return viewServer{}, viewRefused(problem.words(name))
	}
	return s, nil
}

// onViewServer runs body on the server, in words for the person when it fails.
func onViewServer(ctx context.Context, s viewServer, body func(*viewSession) error) error {
	err := withViewSession(ctx, s, body)
	if err == nil {
		return nil
	}
	f := mcpFailureOf(err)
	switch {
	case f.kind == "authRequired":
		log.Printf("mcp views: %s wants a sign-in", s.name)
		return viewRefused(viewSignIn.words(s.name))
	case f.kind == "refused" && f.message != "":
		log.Printf("mcp views: %s did not answer (refused)", s.name)
		msg := f.message
		if utf8.RuneCountInString(msg) > 300 {
			msg = string([]rune(msg)[:300])
		}
		return viewRefused(s.name + " refused: " + msg)
	}
	log.Printf("mcp views: %s did not answer (%s)", s.name, f.kind)
	return viewRefused(s.name + " did not answer: " + f.sentence(viewTimeout))
}

// readView is resources/read, for a view drawn in agentID's conversation, with the policy
// it is to be drawn under. The policy goes in the log, as the spec asks.
func (d *Daemon) readView(ctx context.Context, r wire.ViewReadRequest) (wire.ViewResource, error) {
	if r.Server == nil || *r.Server == appServerName {
		return wire.ViewResource{}, viewRefused("No view at " + r.URI + ".")
	}
	name := *r.Server
	folder, err := d.viewFolder(r.AgentID, r.Folder)
	if err != nil {
		return wire.ViewResource{}, err
	}
	s, err := d.readyViewServer(name, folder)
	if err != nil {
		return wire.ViewResource{}, err
	}
	if !strings.HasPrefix(r.URI, "ui://") {
		return wire.ViewResource{}, viewRefused("Only a ui:// view can be drawn.")
	}
	var contents []map[string]json.RawMessage
	if err := onViewServer(ctx, s, func(m *viewSession) error {
		raw, err := m.call("resources/read", map[string]any{"uri": r.URI})
		if err != nil {
			return err
		}
		var answer struct {
			Contents []map[string]json.RawMessage `json:"contents"`
		}
		if json.Unmarshal(raw, &answer) != nil {
			return &mcpCheckFailure{kind: "notMCP"}
		}
		contents = answer.Contents
		return nil
	}); err != nil {
		return wire.ViewResource{}, err
	}
	var content map[string]json.RawMessage
	for _, c := range contents {
		if uri, _ := stringOf(c["uri"]); uri == r.URI {
			content = c
			break
		}
	}
	if content == nil && len(contents) > 0 {
		content = contents[0]
	}
	if content == nil {
		return wire.ViewResource{}, viewRefused(name + " has no view at " + r.URI + ".")
	}
	mimeType, _ := stringOf(content["mimeType"])
	if strings.ReplaceAll(strings.ToLower(mimeType), " ", "") != viewHTML {
		return wire.ViewResource{}, viewRefused(r.URI + " is not a view this app can draw.")
	}
	var html string
	if text, ok := stringOf(content["text"]); ok {
		html = text
	} else if blob, ok := stringOf(content["blob"]); ok {
		b, err := base64.StdEncoding.DecodeString(blob)
		if err != nil {
			return wire.ViewResource{}, viewRefused(r.URI + " came back empty.")
		}
		html = string(b)
	} else {
		return wire.ViewResource{}, viewRefused(r.URI + " came back empty.")
	}
	ui := objectOf(content["_meta"])["ui"]
	hash := viewHash(r.URI, viewHTML, html, ui)
	switch answer, isNew := d.viewAnswer(s.scope, name, r.URI, hash); answer {
	case "show":
	case "hide":
		return wire.ViewResource{}, viewRefused("You chose not to show " + name +
			"'s views here. Ask Again is on its row in the folder's MCP servers.")
	default:
		log.Printf("view %s of %s: waiting for Show", r.URI, name)
		msg := name + "'s view has changed since you said Show."
		if isNew {
			msg = name + " wants to show a view here."
		}
		return wire.ViewResource{}, &Error{Code: wire.FailureViewNeedsShow, Message: msg,
			Data: wire.ViewAsk{Server: name, URI: r.URI, Hash: hash, IsNew: isNew}}
	}
	uiFields := objectOf(ui)
	policy := viewPolicy(uiFields["csp"])
	who := "a folder page"
	if a := d.Store.Agent(r.AgentID); a != nil {
		who = agentName(a.Title)
	}
	log.Printf("view %s of %s in %s: policy %s", r.URI, name, who, policyLogLine(policy))
	res := wire.ViewResource{URI: r.URI, MimeType: viewHTML, HTML: html, Policy: policy, Variables: viewThemeVariables()}
	var border bool
	if json.Unmarshal(uiFields["prefersBorder"], &border) == nil {
		res.PrefersBorder = &border
	}
	return res, nil
}

// viewHash is MCPApprovals.viewHash: its address, type, HTML and _meta.ui, keys sorted.
func viewHash(uri, mimeType, html string, ui json.RawMessage) string {
	meta := "null"
	if !isNull(ui) {
		meta = canonicalEntry(ui)
	}
	sum := sha256.Sum256([]byte(strings.Join([]string{uri, mimeType, html, meta}, "\x00")))
	return hex.EncodeToString(sum[:])
}

// viewKey is scope|server|uri, under "views" in mcp-approvals.json.
func viewKey(scope, server, uri string) string { return scope + "|" + server + "|" + uri }

// viewAnswer is show, hide, or ask (and whether it was never asked before).
func (d *Daemon) viewAnswer(scope, server, uri, hash string) (string, bool) {
	d.mcpMu.Lock()
	d.mcpApprovalsLocked()
	views := map[string]string{}
	if d.mcpApprovals != nil {
		json.Unmarshal(d.mcpApprovals["views"], &views)
	}
	d.mcpMu.Unlock()
	stored, ok := views[viewKey(scope, server, uri)]
	switch {
	case !ok:
		return "ask", true
	case stored == "show:"+hash:
		return "show", false
	case stored == "hide:"+hash:
		return "hide", false
	}
	return "ask", false
}

// answerViewShow is the person's Show or Don't Show, for this version of the view.
func (d *Daemon) answerViewShow(r wire.ViewShowRequest) error {
	folder, err := d.viewFolder(r.AgentID, r.Folder)
	if err != nil {
		return err
	}
	s, err := d.readyViewServer(r.Server, folder)
	if err != nil {
		return err
	}
	word := "hide"
	if r.Show {
		word = "show"
	}
	if err := d.changeMCPApprovals(true, func(_, views map[string]string) {
		views[viewKey(s.scope, s.name, r.URI)] = word + ":" + r.Hash
	}); err != nil {
		return &Error{Code: CodeInternal, Message: "mcp-approvals.json could not be written."}
	}
	said := "not shown"
	if r.Show {
		said = "shown"
	}
	log.Printf("view %s of %s: %s, by the person", r.URI, s.name, said)
	return nil
}

// callFromView is a view's tools/call: passed through only to the server whose view it is,
// and only for a tool its catalog says a view may call.
func (d *Daemon) callFromView(ctx context.Context, r wire.ViewCallRequest) (wire.JSONValue, error) {
	if r.Server == nil || *r.Server == appServerName {
		if d.Store.Agent(r.AgentID) != nil {
			if other := d.viewServerOf(r.ViewID, r.AgentID); other != "" {
				log.Printf("view %s of %s asked for the %s server's %s: refused", r.ViewID, other, appServerName, r.Name)
				return nil, viewRefused("A view may call only its own server's tools, not the " + appServerName + " server's.")
			}
		}
		if _, err := d.viewFolder(r.AgentID, r.Folder); err != nil {
			return nil, err
		}
		log.Printf("view %s asked for %s, which no view may call", r.ViewID, r.Name)
		return nil, viewRefused("A view may not call " + r.Name + ".")
	}
	name := *r.Server
	folder, err := d.viewFolder(r.AgentID, r.Folder)
	if err != nil {
		return nil, err
	}
	// The server the view is of, as the host wrote it, the folder pinned it or the server
	// shows it (#2032), not as the request says.
	own := false
	if d.Store.Agent(r.AgentID) != nil {
		own = d.viewServerOf(r.ViewID, r.AgentID) == name
	} else {
		f := d.readPins(folder)
		for _, p := range f.pins {
			if p.view != nil && p.view.Server == name {
				own = true
			}
		}
		// Or a server's list view, shown without a pin (#2032).
		for _, v := range d.serverViews(folder, f) {
			own = own || v.View.Server == name
		}
	}
	if !own {
		log.Printf("view %s asked for %s's %s, which is not its server's: refused", r.ViewID, name, r.Name)
		return nil, viewRefused("A view may call only its own server's tools, not the " + name + " server's.")
	}
	s, err := d.readyViewServer(name, folder)
	if err != nil {
		return nil, err
	}
	// The Lineage section (#2941): the host answers it, from its own record.
	if r.Name == lineageViewTool {
		result, err := d.lineageViewResult(s, r.Arguments)
		if err == nil {
			log.Printf("view %s of %s called %s", r.ViewID, name, r.Name)
		} else {
			log.Printf("view %s of %s asked for %s, which only ours may call", r.ViewID, name, r.Name)
		}
		return result, err
	}
	catalog := d.loadViewCatalog(ctx, s)
	if catalog != nil && !catalog.appTool(r.Name) {
		catalog = d.refreshViewCatalog(ctx, s)
	}
	if catalog == nil || !catalog.appTool(r.Name) {
		log.Printf("view %s of %s asked for %s, which no view may call", r.ViewID, name, r.Name)
		return nil, viewRefused("A view may not call " + r.Name + ".")
	}
	if r.Feed != nil && *r.Feed {
		if t := catalog.tool(r.Name); t == nil || !t.feedsPins() {
			log.Printf("pinned view %s asked to be fed by %s's %s, which is not read-only", r.ViewID, name, r.Name)
			return nil, viewRefused(r.Name + " can't feed a pinned view: it is not marked read-only.")
		}
	}
	args := json.RawMessage("{}")
	if !isNull(r.Arguments) {
		args = r.Arguments
	}
	call := map[string]any{"name": r.Name, "arguments": args}
	// The control plane's people, for the github, gitlab and linear servers' Team section
	// and "An agent is on it" (#2951): the server makes no control-plane call of its own.
	if teamFeedingTools[r.Name] {
		if meta := d.teamMeta(ctx, folder); meta != nil {
			call["_meta"] = meta
		}
	}
	var result json.RawMessage
	if err := onViewServer(ctx, s, func(m *viewSession) error {
		var err error
		result, err = m.call("tools/call", call)
		return err
	}); err != nil {
		return nil, err
	}
	log.Printf("view %s of %s called %s", r.ViewID, name, r.Name)
	return result, nil
}

// logFromView is a view's notifications/message, into the host's log.
func (d *Daemon) logFromView(r wire.ViewLogRequest) {
	title := string(r.AgentID)
	if a := d.Store.Agent(r.AgentID); a != nil {
		title = agentName(a.Title)
	}
	text := ""
	if s, ok := stringOf(r.Data); ok {
		text = s
	} else if !isNull(r.Data) {
		text = string(r.Data)
	}
	if utf8.RuneCountInString(text) > 2000 {
		text = string([]rune(text)[:2000])
	}
	level := "info"
	if r.Level != nil {
		level = *r.Level
	}
	log.Printf("view %s in %s [%s]: %s", r.ViewID, title, level, text)
}

// keepViewContext is a view's ui/update-model-context: the last one of each view is told
// to the agent with the person's next message, before their words (takeViewContext).
func (d *Daemon) keepViewContext(r wire.ViewContextRequest) error {
	if d.Store.Agent(r.AgentID) == nil {
		// A folder's page (a pin) has no agent to tell (#189).
		log.Printf("view %s on a folder page asked to update the model's context: refused", r.ViewID)
		return viewRefused("A view on a folder's page has no agent to tell.")
	}
	preface := viewContextPreface("a view", r.Content, r.StructuredContent)
	d.viewMu.Lock()
	defer d.viewMu.Unlock()
	if preface == "" {
		delete(d.viewContexts[r.AgentID], r.ViewID)
		return nil
	}
	if d.viewContexts == nil {
		d.viewContexts = map[wire.UUID]map[wire.UUID]string{}
	}
	if d.viewContexts[r.AgentID] == nil {
		d.viewContexts[r.AgentID] = map[wire.UUID]string{}
	}
	d.viewContexts[r.AgentID][r.ViewID] = preface
	return nil
}

// viewContextPreface is AppViewBridge.contextPreface.
func viewContextPreface(title string, content, structured json.RawMessage) string {
	var parts []string
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	json.Unmarshal(content, &blocks)
	for _, b := range blocks {
		if b.Type == "text" && strings.TrimSpace(b.Text) != "" {
			parts = append(parts, b.Text)
		}
	}
	if !isNull(structured) {
		parts = append(parts, canonicalEntry(structured))
	}
	if len(parts) == 0 {
		return ""
	}
	body := strings.Join(parts, "\n")
	if utf8.RuneCountInString(body) > viewContextLimit {
		body = string([]rune(body)[:viewContextLimit])
	}
	return "The view “" + title + "” in this conversation gave you this context, as the person last left it:\n" + body
}

// takeViewContext is every view's context for agentID, taken: it goes with this message
// and no other.
func (d *Daemon) takeViewContext(agentID wire.UUID) string {
	d.viewMu.Lock()
	kept := d.viewContexts[agentID]
	delete(d.viewContexts, agentID)
	d.viewMu.Unlock()
	keys := make([]string, 0, len(kept))
	for k := range kept {
		keys = append(keys, string(k))
	}
	sort.Strings(keys)
	var out []string
	for _, k := range keys {
		out = append(out, kept[wire.UUID(k)])
	}
	return strings.Join(out, "\n\n")
}

// withViewContext puts what a view asked the agent to know before the person's next
// message, and not in their bubble.
func (d *Daemon) withViewContext(agentID wire.UUID, q wire.QueuedPrompt) wire.QueuedPrompt {
	if q.From != wire.PromptOriginPerson {
		return q
	}
	ctx := d.takeViewContext(agentID)
	if ctx == "" {
		return q
	}
	if q.Preface != nil && *q.Preface != "" {
		ctx = *q.Preface + "\n\n" + ctx
	}
	q.Preface = &ctx
	return q
}

// MARK: Pins (#189, #191)

// viewPinRefusal is why view can't be pinned in folder, or "": by what was last read of
// its server. A view is pinned from where it was drawn, so its catalog is here.
func (d *Daemon) viewPinRefusal(v wire.ViewPin, folder string) string {
	if why := viewProblem(v); why != "" {
		return why
	}
	if v.Server == appServerName {
		return "the " + appServerName + " server has no view at " + v.URI + "."
	}
	s, problem := d.viewServerFor(v.Server, folder)
	if problem != 0 {
		return problem.words(v.Server)
	}
	catalog := d.cachedViewCatalog(s)
	if catalog == nil {
		return "the app hasn't read " + v.Server + "'s views yet. Show one in a chat first."
	}
	t := catalog.tool(v.Tool)
	if t == nil || t.ResourceURI != v.URI {
		return v.Tool + " does not feed " + v.URI + " on " + v.Server + "."
	}
	if !t.feedsPins() {
		return v.Tool + " can't feed a pin: only a tool a view may call and that changes nothing " +
			"(readOnlyHint) can, since opening the pin calls it."
	}
	return ""
}

// viewPinMissing is why a pinned view can't be drawn on this host, or "".
func (d *Daemon) viewPinMissing(v wire.ViewPin, folder string) string {
	if v.Server == appServerName {
		return "no such view"
	}
	s, problem := d.viewServerFor(v.Server, folder)
	if problem != 0 {
		return problem.pinReason()
	}
	catalog := d.cachedViewCatalog(s)
	if catalog == nil {
		return ""
	}
	if t := catalog.tool(v.Tool); t == nil || t.ResourceURI != v.URI || !t.feedsPins() {
		return "no such view"
	}
	return ""
}

// viewPinTitle is the view's own title, as its server gives it, kept with a pin (#905);
// nil when it gives none.
func (d *Daemon) viewPinTitle(v wire.ViewPin, folder string) *string {
	s, problem := d.viewServerFor(v.Server, folder)
	if problem != 0 {
		return nil
	}
	catalog := d.cachedViewCatalog(s)
	if catalog == nil {
		return nil
	}
	r := catalog.resource(v.URI)
	if r == nil || r.Title == nil {
		return nil
	}
	title := strings.TrimSpace(*r.Title)
	if title == "" {
		return nil
	}
	if utf8.RuneCountInString(title) > pinTitleLength {
		title = string([]rune(title)[:pinTitleLength])
	}
	return &title
}

// MARK: The policy a view is drawn under

// viewPolicy is AppViewPolicy(csp:): only plain origins a server declared, and what was
// declared and is not one, refused.
func viewPolicy(csp json.RawMessage) wire.AppViewPolicy {
	fields := objectOf(csp)
	p := wire.AppViewPolicy{ConnectDomains: []string{}, ResourceDomains: []string{}, FrameDomains: []string{},
		BaseUriDomains: []string{}, Refused: []string{}}
	origins := func(key string) []string {
		kept := []string{}
		var values []json.RawMessage
		json.Unmarshal(fields[key], &values)
		for _, v := range values {
			text, ok := stringOf(v)
			origin, good := policyOrigin(text)
			if !ok || !good {
				if ok {
					p.Refused = append(p.Refused, text)
				} else {
					p.Refused = append(p.Refused, string(v))
				}
				continue
			}
			dup := false
			for _, k := range kept {
				dup = dup || k == origin
			}
			if !dup {
				kept = append(kept, origin)
			}
		}
		return kept
	}
	p.ConnectDomains = origins("connectDomains")
	p.ResourceDomains = origins("resourceDomains")
	p.FrameDomains = origins("frameDomains")
	p.BaseUriDomains = origins("baseUriDomains")
	return p
}

// policyOrigin is AppViewPolicy.origin: text as a plain origin, lower-cased.
func policyOrigin(text string) (string, bool) {
	value := strings.ToLower(strings.Trim(text, " \t"))
	scheme := ""
	for _, s := range []string{"https://", "wss://", "http://", "ws://"} {
		if strings.HasPrefix(value, s) {
			scheme = s
			break
		}
	}
	if scheme == "" {
		return "", false
	}
	rest := strings.TrimSuffix(value[len(scheme):], "/")
	host := rest
	if i := strings.LastIndex(rest, ":"); i >= 0 {
		port := rest[i+1:]
		n := 0
		for _, r := range port {
			if r < '0' || r > '9' {
				return "", false
			}
			n = n*10 + int(r-'0')
			if n > 65535 {
				return "", false
			}
		}
		if port == "" || n < 1 {
			return "", false
		}
		host = rest[:i]
	}
	host = strings.TrimPrefix(host, "*.")
	if host == "" || len(host) > 253 {
		return "", false
	}
	for _, label := range strings.Split(host, ".") {
		if label == "" || len(label) > 63 || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
			return "", false
		}
		for _, r := range label {
			if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-') {
				return "", false
			}
		}
	}
	return scheme + rest, true
}

// policyLogLine is AppViewPolicy.logLine: what this view may reach.
func policyLogLine(p wire.AppViewPolicy) string {
	var parts []string
	for _, x := range []struct {
		word string
		list []string
	}{{"connect", p.ConnectDomains}, {"resources", p.ResourceDomains}, {"frames", p.FrameDomains}, {"base", p.BaseUriDomains}} {
		if len(x.list) > 0 {
			parts = append(parts, x.word+" "+strings.Join(x.list, " "))
		}
	}
	line := "strict (no network)"
	if len(parts) > 0 {
		line = strings.Join(parts, "; ")
	}
	if len(p.Refused) > 0 {
		line += "; refused " + strings.Join(p.Refused, " ")
	}
	return line
}

// viewThemeVariables is AppViewTheme.variables: the app's look as MCP Apps' CSS variables,
// each colour a light-dark() pair from Paper, for the web page, which has no copy of its own.
func viewThemeVariables() map[string]string {
	pair := func(c [2]string) string { return "light-dark(" + c[0] + ", " + c[1] + ")" }
	ground, raised, well := [2]string{"#f7f8f9", "#1c1d20"}, [2]string{"#ffffff", "#26282c"}, [2]string{"#f0f2f4", "#2a2d31"}
	wash, rule, ink := [2]string{"#e7eaee", "#33363b"}, [2]string{"#dde1e6", "#3a3e44"}, [2]string{"#1c1d20", "#e8eaed"}
	accent, danger := [2]string{"#1f5fc8", "#7fb0ff"}, [2]string{"#b4232b", "#f08086"}
	success, warning := [2]string{"#2d765c", "#8bc6a7"}, [2]string{"#ba4a13", "#f0a06b"}
	secondaryInk := [2]string{"rgb(28 29 32 / 66%)", "rgb(232 234 237 / 66%)"}
	tertiaryInk := [2]string{"rgb(28 29 32 / 45%)", "rgb(232 234 237 / 45%)"}
	tint := func(c [2]string, percent int) string {
		return pair([2]string{fmt.Sprintf("color-mix(in srgb, %s %d%%, %s)", c[0], percent, ground[0]),
			fmt.Sprintf("color-mix(in srgb, %s %d%%, %s)", c[1], percent, ground[1])})
	}
	out := map[string]string{
		"--color-background-primary":   pair(ground),
		"--color-background-secondary": pair(raised),
		"--color-background-tertiary":  pair(well),
		"--color-background-inverse":   pair(ink),
		"--color-background-ghost":     pair(wash),
		"--color-background-info":      tint(accent, 14),
		"--color-background-danger":    tint(danger, 14),
		"--color-background-success":   tint(success, 14),
		"--color-background-warning":   tint(warning, 14),
		"--color-background-disabled":  pair(wash),
		"--color-text-primary":         pair(ink),
		"--color-text-secondary":       pair(secondaryInk),
		"--color-text-tertiary":        pair(tertiaryInk),
		"--color-text-inverse":         pair(ground),
		"--color-text-info":            pair(accent),
		"--color-text-danger":          pair(danger),
		"--color-text-success":         pair(success),
		"--color-text-warning":         pair(warning),
		"--color-text-disabled":        pair(tertiaryInk),
		"--color-text-ghost":           pair(tertiaryInk),
		"--color-border-primary":       pair(rule),
		"--color-border-secondary":     pair(rule),
		"--color-border-tertiary":      pair(wash),
		"--color-border-inverse":       pair(ink),
		"--color-border-ghost":         pair(wash),
		"--color-border-info":          pair(accent),
		"--color-border-danger":        pair(danger),
		"--color-border-success":       pair(success),
		"--color-border-warning":       pair(warning),
		"--color-border-disabled":      pair(rule),
		"--color-ring-primary":         pair(accent),
		"--color-ring-secondary":       pair(rule),
		"--color-ring-inverse":         pair(ground),
		"--color-ring-info":            pair(accent),
		"--color-ring-danger":          pair(danger),
		"--color-ring-success":         pair(success),
		"--color-ring-warning":         pair(warning),
		"--font-sans":                  "-apple-system, BlinkMacSystemFont, system-ui, sans-serif",
		"--font-mono":                  "ui-monospace, \"SF Mono\", Menlo, monospace",
		"--font-weight-normal":         "400",
		"--font-weight-medium":         "500",
		"--font-weight-semibold":       "600",
		"--font-weight-bold":           "700",
		"--border-radius-xs":           "4px",
		"--border-radius-sm":           "7px",
		"--border-radius-md":           "10px",
		"--border-radius-lg":           "16px",
		"--border-radius-xl":           "20px",
		"--border-radius-full":         "9999px",
		"--border-width-regular":       "1px",
		"--shadow-hairline":            "0 0 0 1px " + pair(rule),
		"--shadow-sm":                  "0 1px 2px rgb(32 36 42 / 10%)",
		"--shadow-md":                  "0 2px 6px rgb(32 36 42 / 10%)",
		"--shadow-lg":                  "0 6px 16px rgb(32 36 42 / 12%)",
	}
	for _, t := range []struct {
		name         string
		size, height int
	}{{"xs", 11, 14}, {"sm", 12, 16}, {"md", 14, 20}, {"lg", 16, 24}} {
		out["--font-text-"+t.name+"-size"] = fmt.Sprintf("%dpx", t.size)
		out["--font-text-"+t.name+"-line-height"] = fmt.Sprintf("%dpx", t.height)
	}
	for _, t := range []struct {
		name         string
		size, height int
	}{{"xs", 12, 16}, {"sm", 14, 20}, {"md", 16, 22}, {"lg", 20, 26}, {"xl", 24, 30}, {"2xl", 28, 34}, {"3xl", 34, 40}} {
		out["--font-heading-"+t.name+"-size"] = fmt.Sprintf("%dpx", t.size)
		out["--font-heading-"+t.name+"-line-height"] = fmt.Sprintf("%dpx", t.height)
	}
	return out
}

// pinned is whether path (a view's ui:// address) is pinned in folder already.
func (d *Daemon) pinned(folder, path string) bool {
	for _, e := range d.readPins(folder).pins {
		if e.path == path {
			return true
		}
	}
	return false
}
