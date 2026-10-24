package agentsd

import (
	"bytes"
	"context"
	"errors"
	"html"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/Go/internal/agentsd/mcpcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Signing in to a person's MCP server (DaemonCore+MCPSignIn, #306). The daemon is the OAuth
// client: it finds where to sign in, registers itself or uses the person's own client,
// makes the PKCE pair, listens for the browser on loopback, exchanges the code and keeps
// the grant in ~/.agents-secrets/mcp-sign-ins.json. The window only opens the page and
// waits. Logged: the server's name and what happened, in a word.

func (d *Daemon) registerMCPSignIn() {
	On(d, wire.CallMCPSignIn, func(ctx context.Context, c *Client, r wire.MCPSignInRequest) (wire.MCPSignInAnswer, error) {
		return d.mcpSignIn(ctx, r), nil
	})
	On(d, wire.CallMCPSignInWait, func(ctx context.Context, c *Client, r wire.MCPSignInFlowRequest) (wire.MCPSignInWaitAnswer, error) {
		answer := d.mcpSignInWait(ctx, r.FlowID)
		if answer.Status.SignedIn != nil {
			d.mcpChanged()
		}
		return answer, nil
	})
	On(d, wire.CallMCPSignInCancel, func(ctx context.Context, c *Client, r wire.MCPSignInFlowRequest) (wire.MCPSignInWaitAnswer, error) {
		return d.mcpSignInCancel(r.FlowID), nil
	})
	On(d, wire.CallMCPSignOut, func(ctx context.Context, c *Client, r wire.MCPSignOutRequest) (wire.MCPSignOutAnswer, error) {
		answer := d.mcpSignOut(ctx, r.Target)
		d.mcpChanged()
		return answer, nil
	})
}

var (
	// mcpSignInLifetime is how long a sign-in waits for the browser.
	mcpSignInLifetime = 10 * time.Minute
	// mcpSignInWaitLimit is one long poll of mcp/sign-in/wait.
	mcpSignInWaitLimit = 25 * time.Second
	// mcpSignInProbeTimeout is how long a list asks a server whether it wants a sign-in.
	mcpSignInProbeTimeout = 5 * time.Second
	mcpSignInHTTP         = &http.Client{}
)

type signInState struct {
	signIns *mcpcatalog.SignIns
	mu      sync.Mutex
	flows   map[wire.UUID]*signInFlow
}

var signInStates sync.Map // *Daemon → *signInState

func (d *Daemon) signIn() *signInState {
	if s, ok := signInStates.Load(d); ok {
		return s.(*signInState)
	}
	s, _ := signInStates.LoadOrStore(d, &signInState{flows: map[wire.UUID]*signInFlow{},
		signIns: &mcpcatalog.SignIns{Home: d.personalHome(), OAuth: mcpcatalog.OAuth{Client: mcpSignInHTTP},
			Log: func(l string) { log.Print(l) }}})
	return s.(*signInState)
}

// signInFlow is one sign-in under way, waited on by the window a long poll at a time.
type signInFlow struct {
	id     wire.UUID
	name   string
	server string
	once   sync.Once
	done   chan struct{}
	status wire.MCPSignInStatus
	stop   func()
	mu     sync.Mutex
	cancel bool
}

func (f *signInFlow) complete(s wire.MCPSignInStatus) {
	f.once.Do(func() { f.status = s; close(f.done) })
}

func (f *signInFlow) cancelled() bool { f.mu.Lock(); defer f.mu.Unlock(); return f.cancel }

func (f *signInFlow) doCancel() {
	f.mu.Lock()
	f.cancel = true
	f.mu.Unlock()
	if f.stop != nil {
		f.stop()
	}
	f.complete(wire.MCPSignInStatus{Cancelled: &struct{}{}})
}

func failed(why string) wire.MCPSignInStatus {
	return wire.MCPSignInStatus{Failed: &wire.MCPSignInStatusFailed{Value: why}}
}

// signInWords is a failure as the sheet says it.
func signInWords(err error) string {
	var of *mcpcatalog.OAuthFailure
	var ce *mcpcatalog.Error
	var mf *mcpCheckFailure
	switch {
	case errors.As(err, &of):
		return of.Sentence()
	case errors.As(err, &ce):
		return ce.Error()
	case errors.Is(err, mcpcatalog.ErrSignInsUnreadable):
		return mcpcatalog.SignInFileName + " could not be read, so nothing was written to it. Check it in ~/.agents."
	case errors.As(err, &mf):
		return mf.sentence(15 * time.Second)
	}
	return "The sign-in couldn't start."
}

func signInLogWord(err error) string {
	var of *mcpcatalog.OAuthFailure
	if errors.As(err, &of) {
		return of.LogWord()
	}
	if errors.Is(err, mcpcatalog.ErrSignInsUnreadable) {
		return "file unreadable"
	}
	return "failed"
}

// mcpSignInServer is the http server to sign in to, its secrets filled: in the
// destination's mcp.json, or typed on the sheet.
func (d *Daemon) mcpSignInServer(t wire.MCPSignInTarget) (string, []sdk.HttpHeader, error) {
	if t.URL != nil {
		if _, ok := mcpcatalog.Canonical(t.URL.URL); !ok {
			return "", nil, invalid("That is not an http or https address.")
		}
		return t.URL.URL, nil, nil
	}
	if t.Entry == nil {
		return "", nil, invalid("Name a server to sign in to.")
	}
	if err := d.requireMCPFolder(t.Entry.Destination); err != nil {
		return "", nil, err
	}
	if d.personalHome() == "" {
		return "", nil, mcpcatalog.NoPersonalHome()
	}
	path, err := d.mcpFile(t.Entry.Destination)
	if err != nil {
		return "", nil, err
	}
	entries, problem := readMCPFile(path)
	if problem != "" {
		return "", nil, mcpcatalog.Unreadable(path)
	}
	for _, e := range entries {
		if e.name != t.Entry.Name {
			continue
		}
		filled, missing := filledServer(e.server, d.secrets())
		if len(missing) > 0 {
			return "", nil, mcpcatalog.MissingSecret(missing[0])
		}
		if filled.Http == nil {
			return "", nil, invalid("Only a remote (http) server is signed in to.")
		}
		return filled.Http.Url, filled.Http.Headers, nil
	}
	return "", nil, invalid("There is no server called " + t.Entry.Name + " there any more.")
}

func signInName(t wire.MCPSignInTarget) string {
	if t.Entry != nil {
		return t.Entry.Name
	}
	if t.URL != nil {
		return t.URL.Name
	}
	return "the server"
}

func bringsOwn(headers []sdk.HttpHeader) bool {
	for _, h := range headers {
		if strings.EqualFold(h.Name, "Authorization") {
			return true
		}
	}
	return false
}

// probeSignIn asks a server for a session: whether it wants a sign-in, and where its
// resource metadata is when its 401 says.
func probeSignIn(ctx context.Context, server string, headers []sdk.HttpHeader, timeout time.Duration) (wants bool, metadata string) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	body := request(1, "initialize", map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{},
		"clientInfo": map[string]any{"name": "Agents", "version": "1"}})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, server, bytes.NewReader(body))
	if err != nil {
		return false, ""
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	for _, h := range headers {
		req.Header.Set(h.Name, h.Value)
	}
	res, err := mcpSignInHTTP.Do(req)
	if err != nil {
		return false, ""
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusUnauthorized {
		if s := res.Header.Get("Mcp-Session-Id"); s != "" {
			end, _ := http.NewRequest(http.MethodDelete, server, nil)
			end.Header.Set("Mcp-Session-Id", s)
			safe.Go("mcp probe end", func() {
				if r, err := mcpSignInHTTP.Do(end); err == nil {
					r.Body.Close()
				}
			})
		}
		return false, ""
	}
	return true, mcpcatalog.ResourceMetadata(res.Header.Get("WWW-Authenticate"))
}

func (d *Daemon) mcpSignIn(ctx context.Context, r wire.MCPSignInRequest) wire.MCPSignInAnswer {
	name := signInName(r.Target)
	refuse := func(err error) wire.MCPSignInAnswer {
		log.Printf("mcp sign-in: %s could not start (%s)", name, signInLogWord(err))
		words := signInWords(err)
		return wire.MCPSignInAnswer{Error: &words}
	}
	server, headers, err := d.mcpSignInServer(r.Target)
	if err != nil {
		log.Printf("mcp sign-in: %s refused", name)
		words := signInWords(err)
		return wire.MCPSignInAnswer{Error: &words}
	}
	if bringsOwn(headers) {
		words := name + " is sent an Authorization header of its own, so the app doesn't sign in to it. " +
			"Take the header out of its entry to sign in instead."
		return wire.MCPSignInAnswer{Error: &words}
	}
	st := d.signIn()
	// A sign-in already under way for this server is replaced by this one.
	st.mu.Lock()
	for id, f := range st.flows {
		if f.server == server {
			f.doCancel()
			delete(st.flows, id)
		}
	}
	st.mu.Unlock()

	oauth := st.signIns.OAuth
	metadata := st.signIns.ResourceMetadata(server)
	if metadata == "" {
		// Ask the server itself: its 401 says where its metadata is.
		_, metadata = probeSignIn(ctx, server, headers, 15*time.Second)
	}
	plan, err := oauth.Discover(ctx, server, metadata)
	if err != nil {
		return refuse(err)
	}
	var client *mcpcatalog.Client
	var personsOwn *mcpcatalog.Client
	switch {
	case r.Client != nil && strings.TrimSpace(r.Client.ID) != "":
		c := mcpcatalog.Client{ID: strings.TrimSpace(r.Client.ID)}
		if r.Client.Secret != nil && strings.TrimSpace(*r.Client.Secret) != "" {
			s := strings.TrimSpace(*r.Client.Secret)
			c.Secret = &s
		}
		// Kept once it has signed in, so a mistyped one is asked for again.
		client, personsOwn = &c, &c
	default:
		if kept, ok := st.signIns.ClientFor(plan.Server); ok {
			client = &kept
		} else if plan.Server.RegistrationEndpoint == nil {
			log.Printf("mcp sign-in: %s needs a client of the person's own", name)
			issuer, callback := plan.Server.Issuer, "http://127.0.0.1/callback"
			return wire.MCPSignInAnswer{NeedsClient: &issuer, Callback: &callback}
		}
	}

	state, verifier := mcpcatalog.RandomToken(), mcpcatalog.RandomToken()
	redirect, err := listenForCallback(state)
	if err != nil {
		return refuse(err)
	}
	registered := mcpcatalog.Client{}
	if client != nil {
		registered = *client
	} else if registered, err = oauth.Register(ctx, *plan.Server.RegistrationEndpoint, redirect.address()); err != nil {
		redirect.stop()
		return refuse(err)
	}
	address, ok := mcpcatalog.AuthorizationURL(plan, registered, redirect.address(), state, mcpcatalog.Challenge(verifier))
	if !ok {
		redirect.stop()
		return refuse(&mcpcatalog.OAuthFailure{Kind: "malformed"})
	}
	flow := &signInFlow{id: store.NewUUID(), name: name, server: server, done: make(chan struct{}), stop: redirect.stop}
	st.mu.Lock()
	st.flows[flow.id] = flow
	st.mu.Unlock()
	time.AfterFunc(mcpSignInLifetime, redirect.stop)
	safe.Go("mcp sign-in", func() {
		flow.complete(d.finishSignIn(flow, redirect, plan, registered, verifier, personsOwn))
	})
	log.Printf("mcp sign-in: %s waiting for the browser", name)
	return wire.MCPSignInAnswer{FlowID: &flow.id, AuthorizationURL: &address}
}

// finishSignIn is the browser's return: the code exchanged, the grant kept, a page to say so.
func (d *Daemon) finishSignIn(flow *signInFlow, redirect *loopback, plan mcpcatalog.Plan, client mcpcatalog.Client,
	verifier string, given *mcpcatalog.Client) wire.MCPSignInStatus {
	name := flow.name
	query, ok := redirect.callback()
	if !ok {
		if flow.cancelled() {
			return wire.MCPSignInStatus{Cancelled: &struct{}{}}
		}
		log.Printf("mcp sign-in: %s not finished in time", name)
		return failed("The sign-in wasn't finished in time. Start it again.")
	}
	fail := func(f *mcpcatalog.OAuthFailure) wire.MCPSignInStatus {
		redirect.finish("Sign-in didn't finish", f.Sentence()+" You can close this tab.")
		log.Printf("mcp sign-in: %s failed (%s)", name, f.LogWord())
		return failed(f.Sentence())
	}
	if e := query["error"]; e != "" {
		if e == "access_denied" {
			redirect.finish("Sign-in cancelled", "Nothing was kept. You can close this tab.")
			log.Printf("mcp sign-in: %s declined in the browser", name)
			return failed("The sign-in was declined in the browser.")
		}
		why := query["error_description"]
		if why == "" {
			why = e
		}
		if len(why) > 200 {
			why = why[:200]
		}
		return fail(&mcpcatalog.OAuthFailure{Kind: "refused", Why: why})
	}
	// RFC 9207: an iss that is not the issuer asked is a mix-up.
	if iss, ok := query["iss"]; ok && iss != plan.Server.Issuer {
		return fail(&mcpcatalog.OAuthFailure{Kind: "refused", Why: "It came back from another server."})
	}
	code := query["code"]
	if code == "" {
		return fail(&mcpcatalog.OAuthFailure{Kind: "malformed"})
	}
	st := d.signIn()
	tokens, err := st.signIns.OAuth.Exchange(context.Background(), code, verifier, redirect.address(), client, plan)
	if err != nil {
		var f *mcpcatalog.OAuthFailure
		if errors.As(err, &f) {
			return fail(f)
		}
		return fail(&mcpcatalog.OAuthFailure{Kind: "unreachable"})
	}
	if err := st.signIns.Keep(flow.server, name, plan, client, tokens); err != nil {
		redirect.finish("Sign-in didn't finish", "The sign-in couldn't be kept. You can close this tab.")
		log.Printf("mcp sign-in: %s could not be kept", name)
		return failed("The sign-in couldn't be kept: " + mcpcatalog.SignInFileName + " could not be read or written.")
	}
	if given != nil {
		st.signIns.KeepClient(*given, plan.Server)
	}
	redirect.finish("Signed in to "+name, "The next agent you start has it. You can close this tab and go back to Agents.")
	return wire.MCPSignInStatus{SignedIn: &struct{}{}}
}

func (d *Daemon) mcpSignInWait(ctx context.Context, id wire.UUID) wire.MCPSignInWaitAnswer {
	st := d.signIn()
	st.mu.Lock()
	flow, ok := st.flows[id]
	st.mu.Unlock()
	if !ok {
		return wire.MCPSignInWaitAnswer{Status: failed("That sign-in has ended. Start it again.")}
	}
	select {
	case <-flow.done:
		st.mu.Lock()
		delete(st.flows, id)
		st.mu.Unlock()
		return wire.MCPSignInWaitAnswer{Status: flow.status}
	case <-time.After(mcpSignInWaitLimit):
	case <-ctx.Done():
	}
	return wire.MCPSignInWaitAnswer{Status: wire.MCPSignInStatus{Waiting: &struct{}{}}}
}

func (d *Daemon) mcpSignInCancel(id wire.UUID) wire.MCPSignInWaitAnswer {
	st := d.signIn()
	st.mu.Lock()
	flow, ok := st.flows[id]
	delete(st.flows, id)
	st.mu.Unlock()
	if ok {
		flow.doCancel()
		log.Printf("mcp sign-in: %s cancelled", flow.name)
	}
	return wire.MCPSignInWaitAnswer{Status: wire.MCPSignInStatus{Cancelled: &struct{}{}}}
}

func (d *Daemon) mcpSignOut(ctx context.Context, t wire.MCPSignInTarget) wire.MCPSignOutAnswer {
	server, _, err := d.mcpSignInServer(t)
	if err == nil {
		err = d.signIn().signIns.SignOut(ctx, server, signInName(t))
	}
	if err != nil {
		log.Printf("mcp sign-in: %s sign-out refused", signInName(t))
		words := signInWords(err)
		return wire.MCPSignOutAnswer{Error: &words}
	}
	return wire.MCPSignOutAnswer{}
}

// mcpSignInStates is each row's sign-in, from what is kept, asking an http server that has
// not been asked this run once, briefly: an approved one, with no Authorization of its own.
func (d *Daemon) mcpSignInStates(rows []wire.FolderMCPServer, dest wire.SkillDestination) []wire.FolderMCPServer {
	path, err := d.mcpFile(dest)
	if err != nil {
		return rows
	}
	entries, problem := readMCPFile(path)
	if problem != "" {
		return rows
	}
	secrets := d.secrets()
	signIns := d.signIn().signIns
	for i := range rows {
		if rows[i].Approval.Approved == nil || len(rows[i].MissingSecrets) > 0 {
			continue
		}
		for _, e := range entries {
			if e.name != rows[i].Name {
				continue
			}
			filled, _ := filledServer(e.server, secrets)
			if filled.Http == nil || bringsOwn(filled.Http.Headers) {
				continue
			}
			url := filled.Http.Url
			if state := signIns.State(url); state != "" {
				s := wire.MCPSignInState(state)
				rows[i].SignIn = &s
				continue
			}
			if signIns.WasProbed(url) {
				continue
			}
			if wants, metadata := probeSignIn(context.Background(), url, filled.Http.Headers, mcpSignInProbeTimeout); wants {
				signIns.MarkNeedsSignIn(url, e.name, metadata)
				s := wire.MCPSignInStateNeedsSignIn
				rows[i].SignIn = &s
			} else {
				signIns.NoteProbe(url, false)
			}
		}
	}
	return rows
}

// withSignIns is a session's servers, each http one the app signed in to with its bearer,
// and those that need a sign-in left out.
func (d *Daemon) withSignIns(servers []sdk.McpServer) []sdk.McpServer {
	if d.personalHome() == "" {
		return servers
	}
	signIns := d.signIn().signIns
	out := make([]sdk.McpServer, 0, len(servers))
	for _, s := range servers {
		if s.Http == nil || s.Http.Name == appServerName || bringsOwn(s.Http.Headers) {
			out = append(out, s)
			continue
		}
		switch b := signIns.BearerFor(context.Background(), s.Http.Url, s.Http.Name); b.Kind {
		case "token":
			h := *s.Http
			h.Headers = append(append([]sdk.HttpHeader{}, h.Headers...), sdk.HttpHeader{Name: "Authorization", Value: "Bearer " + b.Token})
			out = append(out, sdk.McpServer{Http: &h})
		case "needsSignIn":
			log.Printf("mcp sign-in: %s left out of a session: it needs a sign-in", s.Http.Name)
		default:
			out = append(out, s)
		}
	}
	return out
}

// loopback is where the browser comes back to: http://127.0.0.1:PORT/callback, open for one
// sign-in. Only a request with this sign-in's state is the callback; nothing a request
// carries is logged.
type loopback struct {
	state    string
	listener net.Listener
	server   *http.Server
	once     sync.Once
	arrived  chan map[string]string
	page     chan [2]string
	stopped  chan struct{}
	stopOnce sync.Once
}

func listenForCallback(state string) (*loopback, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	lb := &loopback{state: state, listener: l, arrived: make(chan map[string]string, 1), page: make(chan [2]string, 1),
		stopped: make(chan struct{})}
	lb.server = &http.Server{Handler: http.HandlerFunc(lb.serve), ReadHeaderTimeout: 10 * time.Second}
	safe.Go("mcp sign-in redirect", func() { lb.server.Serve(l) })
	return lb, nil
}

func (lb *loopback) address() string {
	return "http://127.0.0.1:" + strings.TrimPrefix(lb.listener.Addr().String(), "127.0.0.1:") + "/callback"
}

func (lb *loopback) serve(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Cache-Control", "no-store")
	h.Set("Referrer-Policy", "no-referrer")
	if r.Method != http.MethodGet || r.URL.Path != "/callback" {
		http.NotFound(w, r)
		return
	}
	query := map[string]string{}
	for k, v := range r.URL.Query() {
		if len(v) > 0 {
			query[k] = v[0]
		}
	}
	if query["state"] != lb.state {
		h.Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte("This isn't the sign-in Agents is waiting for."))
		return
	}
	first := false
	lb.once.Do(func() { first = true; lb.arrived <- query })
	if !first {
		h.Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusConflict)
		w.Write([]byte("This sign-in is already done."))
		return
	}
	select {
	case p := <-lb.page:
		h.Set("Content-Type", "text/html; charset=utf-8")
		w.Write([]byte(`<!doctype html><meta charset="utf-8"><title>` + html.EscapeString(p[0]) + `</title>` +
			`<body style="font: 15px -apple-system, sans-serif; margin: 4em auto; max-width: 32em; color: #222">` +
			`<h1 style="font-size: 20px">` + html.EscapeString(p[0]) + `</h1><p>` + html.EscapeString(p[1]) + `</p></body>`))
	case <-time.After(time.Minute):
	}
}

// callback is the query the browser came back with, or false when it stopped first.
func (lb *loopback) callback() (map[string]string, bool) {
	select {
	case q := <-lb.arrived:
		return q, true
	case <-lb.stopped:
		return nil, false
	}
}

// finish shows the browser a page, and stops listening once it is sent.
func (lb *loopback) finish(title, body string) {
	select {
	case lb.page <- [2]string{title, body}:
	default:
	}
	time.AfterFunc(2*time.Second, lb.stop)
}

func (lb *loopback) stop() {
	lb.stopOnce.Do(func() {
		close(lb.stopped)
		lb.server.Close()
	})
}
